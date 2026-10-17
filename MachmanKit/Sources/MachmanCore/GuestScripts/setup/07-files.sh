# === machman-setup: 07-files ===
# The link-safe file edits every change to a guest file goes through (05-lib's house rules
# hold here too).

# ------------------------------------------------------------------- marked-file edits ----
#
# Every file this script edits goes through rewrite_file, every file it writes whole goes
# through write_file. Root runs them over files other users own (~/.ssh, the sshfs mount
# root, the report drop-box), so neither ever writes through anything a user can plant:
#   * pinned: a subshell cd -P's into the file's directory, which must itself be real (not
#     a link), and from there touches only names relative to it;
#   * never through a link: a symlinked or non-regular target is refused, and so is a
#     hard-linked one for an edit — a dotfile-managed ~/.ssh entry gets a named refusal,
#     never a silent rewrite;
#   * a fresh name: the content goes into ".<name>.machman-<random>~", created exclusively
#     (set -C) by the very open that writes it, then renamed over the target;
#   * the old file's owner (chown -h) and mode: rw bits through the umask at creation,
#     x/setuid/sticky by chmod, and only in a directory no other user can rename names in;
#   * read through one open: an edit opens the file once and refuses unless that is the
#     file it checked — a link swapped in after the check would have root copy what it can
#     read into the user's file. BSD stat reads the descriptor itself (macOS, FreeBSD,
#     OpenBSD, NetBSD); elsewhere /dev/fd shows what it holds (Linux);
#   * an empty result empties the file instead of failing: filters are awk or sed, which
#     exit 0 whatever they keep (grep -v exits 1 when nothing is left).
# Paths are absolute. A refusal or failure returns 1 with R_ERROR set and the target
# untouched; the caller decides between step_failed, a warning and giving up. One race
# stays open, as POSIX sh cannot close it without dropping privileges: a link to a
# directory swapped in just before the rename, which receives the new file there, under
# its inert dot-and-tilde name. (The read goes unchecked only where neither stat nor
# /dev/fd can see an open file.)

# rewrite_file [-m <mode>] [-o <user:group>] <file> <filter> [args…] — the file becomes
# what <filter> prints when fed the file; -m/-o set the result's mode/owner instead.
rewrite_file() {
	_rf_fmode=""
	_rf_fown=""
	while :; do
		case "$1" in
		-m) _rf_fmode="$2"; shift 2 ;;
		-o) _rf_fown="$2"; shift 2 ;;
		*) break ;;
		esac
	done
	_rf_path="$1"
	shift
	R_ERROR=""
	_rf_code=0
	( _rf_in_dir rewrite "$_rf_path" "$@" ) || _rf_code=$?
	[ "$_rf_code" -eq 0 ] && return 0
	R_ERROR="$(_rf_reason "$_rf_code" "$_rf_path")"
	return 1
}

# write_file [-m <mode>] [-o <user:group>] <file> — stdin becomes <file> (mode 644 unless
# -m): created, or replaced by rename — whatever stood there, a link included, is never
# written through.
write_file() {
	_rf_fmode=644
	_rf_fown=""
	while :; do
		case "$1" in
		-m) _rf_fmode="$2"; shift 2 ;;
		-o) _rf_fown="$2"; shift 2 ;;
		*) break ;;
		esac
	done
	R_ERROR=""
	_rf_code=0
	( _rf_in_dir write "$1" cat ) || _rf_code=$?
	[ "$_rf_code" -eq 0 ] && return 0
	R_ERROR="$(_rf_reason "$_rf_code" "$1")"
	return 1
}

# A plain file this script may read and edit: there, regular, not a link.
regular_file() {
	[ -f "$1" ] && [ ! -L "$1" ]
}

_rf_reason() { # <code> <path>
	case "$1" in
	10) printf '%s is not an absolute path in an existing directory' "$2" ;;
	11) printf '%s is reached through a symbolic link' "$2" ;;
	12) printf '%s is a symbolic link' "$2" ;;
	13) printf '%s is not a regular file' "$2" ;;
	14) printf '%s has other hard links' "$2" ;;
	16) printf '%s changed while it was being edited' "$2" ;;
	*) printf 'could not write %s' "$2" ;;
	esac
}

# <rewrite|write> <path> <filter> [args…] — only ever run in a subshell (it cd's and
# exits with a reason code).
_rf_in_dir() {
	_rf_op="$1"
	case "$2" in
	/*) ;;
	*) exit 10 ;;
	esac
	_rf_dir="$(dirname "$2")"
	_rf_name="$(basename "$2")"
	shift 2
	cd -P "$_rf_dir" 2>/dev/null || exit 10
	# Only the last directory is checked: the swap that matters is a user's own directory
	# (~/.ssh) turned into a link to someone else's. Links further up (FreeBSD's /home,
	# macOS's /tmp) are the system's own.
	_rf_up="$(cd -P "$(dirname "$_rf_dir")" 2>/dev/null && pwd -P)" || exit 10
	[ "$_rf_dir" = / ] || [ "$(pwd -P)" = "${_rf_up%/}/$(basename "$_rf_dir")" ] || exit 11
	_rf_perm=""
	_rf_uid=""
	_rf_gid=""
	if [ -L "./$_rf_name" ]; then
		[ "$_rf_op" = write ] || exit 12
	elif [ -e "./$_rf_name" ]; then
		[ -f "./$_rf_name" ] || exit 13
		# Numeric, and every field ahead of the name: spaces in it never shift one.
		read -r _rf_ino _rf_perm _rf_links _rf_uid _rf_gid _rf_rest <<EOF
$(ls -lni "./$_rf_name")
EOF
		# An edit would split a hard link (the other name keeps the old text); a whole
		# new file replaces this name only, by design.
		[ "$_rf_op" = write ] || [ "$_rf_links" = 1 ] || exit 14
	else
		[ "$_rf_op" = write ] || exit 13
	fi
	[ "$_rf_op" = write ] && { _rf_uid=""; _rf_gid=""; }
	# The result's mode, in octal: forced, else the old file's.
	if [ -n "$_rf_fmode" ]; then
		_rf_mode="$_rf_fmode"
	else
		_rf_mode="$(printf '%s\n' "$_rf_perm" | awk '{
			m = 0
			if (substr($0, 2, 1) == "r") m += 256
			if (substr($0, 3, 1) == "w") m += 128
			c = substr($0, 4, 1); if (c == "x" || c == "s") m += 64; if (c ~ /[sS]/) m += 2048
			if (substr($0, 5, 1) == "r") m += 32
			if (substr($0, 6, 1) == "w") m += 16
			c = substr($0, 7, 1); if (c == "x" || c == "s") m += 8; if (c ~ /[sS]/) m += 1024
			if (substr($0, 8, 1) == "r") m += 4
			if (substr($0, 9, 1) == "w") m += 2
			c = substr($0, 10, 1); if (c == "x" || c == "t") m += 1; if (c ~ /[tT]/) m += 512
			printf "%o\n", m }')"
	fi
	# "<umask for the rw bits> <1 when x/setuid/setgid/sticky bits need a chmod>"
	read -r _rf_umask _rf_extra <<EOF
$(printf '%s\n' "$_rf_mode" | awk '{
	v = 0
	for (i = 1; i <= length($0); i++) v = v * 8 + substr($0, i, 1)
	rw = 0
	if (int(v / 256) % 2) rw += 256; if (int(v / 128) % 2) rw += 128
	if (int(v / 32) % 2) rw += 32;   if (int(v / 16) % 2) rw += 16
	if (int(v / 4) % 2) rw += 4;     if (int(v / 2) % 2) rw += 2
	extra = (v > rw) ? 1 : 0
	printf "%o %d\n", 438 - rw, extra }')
EOF
	_rf_rand="$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
	[ -n "$_rf_rand" ] || exit 15
	_rf_tmp="./.$_rf_name.machman-$_rf_rand~"
	if [ "$_rf_op" = write ]; then
		( umask "$_rf_umask" && set -C && "$@" > "$_rf_tmp" ) || { rm -f "$_rf_tmp"; exit 15; }
	else
		# One open, checked against the file checked above before anything reads it.
		command exec 8< "./$_rf_name" || exit 13
		if _rf_stat_shows_fds; then
			[ "$(stat -f '%i %u %g' <&8 2>/dev/null)" = "$_rf_ino $_rf_uid $_rf_gid" ] \
				|| exit 16
		elif _rf_fd_shows_files; then
			read -r _rf_oino _rf_operm _rf_olinks _rf_ouid _rf_ogid _rf_rest <<EOF
$(ls -lniL /dev/fd/7 7<&8 2>/dev/null)
EOF
			[ "${_rf_oino:-} ${_rf_ouid:-} ${_rf_ogid:-}" = "$_rf_ino $_rf_uid $_rf_gid" ] \
				|| exit 16
		fi
		( umask "$_rf_umask" && set -C && "$@" <&8 > "$_rf_tmp" ) \
			|| { rm -f "$_rf_tmp"; exit 15; }
	fi
	if [ -n "$_rf_fown" ]; then
		chown -h "$_rf_fown" "$_rf_tmp" || { rm -f "$_rf_tmp"; exit 15; }
	elif [ -n "$_rf_uid" ]; then
		chown -h "$_rf_uid:$_rf_gid" "$_rf_tmp" || { rm -f "$_rf_tmp"; exit 15; }
	fi
	if [ "$_rf_extra" = 1 ]; then
		read -r _rf_dperm _rf_dlinks _rf_duid _rf_rest <<EOF
$(ls -lnd .)
EOF
		if [ "$_rf_duid" = "$(id -u)" ]; then
			chmod "$_rf_mode" "$_rf_tmp" || { rm -f "$_rf_tmp"; exit 15; }
		fi
	fi
	# A link standing where write_file writes goes first: mv would follow one that
	# points at a directory and land the file inside it.
	[ -L "./$_rf_name" ] && rm -f "./$_rf_name"
	mv -f "$_rf_tmp" "./$_rf_name" || { rm -f "$_rf_tmp"; exit 15; }
	exit 0
}

# Whether stat reads the file a descriptor has open (BSD stat: stdin, given no file): an
# open "/" must read as "/" (inode, owner, group). GNU and busybox stat take -f for the
# file system and want an operand, so they fail this and the /dev/fd check below runs.
_rf_stat_shows_fds() {
	_rf_ss_root="$(ls -lnid / 2>/dev/null | awk '{ print $1, $4, $5 }')"
	[ -n "$_rf_ss_root" ] && [ "$_rf_ss_root" = "$( (command exec 9< / \
		&& stat -f '%i %u %g' <&9) 2>/dev/null)" ]
}

# Whether /dev/fd shows the file a descriptor has open rather than a node of its own: an
# open "/" must look like "/" (inode, owner, group). Only the edit's read checks this, so
# where it fails that read goes unverified, as before. The descriptor is handed to ls on a
# fresh number: ksh-line shells close the ones exec opened when they run a command, and a
# descriptor duplicated onto itself (8<&8) keeps that flag.
_rf_fd_shows_files() {
	_rf_fs_root="$(ls -lnid / 2>/dev/null | awk '{ print $1, $4, $5 }')"
	[ -n "$_rf_fs_root" ] && [ "$_rf_fs_root" = "$( (command exec 9< / \
		&& ls -lniLd /dev/fd/7 7<&9) 2>/dev/null | awk '{ print $1, $4, $5 }')" ]
}

# Filters: stdin to stdout, exit 0 whatever they keep.

# <marker> — without that marker's "# BEGIN"…"# END" blocks. An unclosed BEGIN keeps its
# lines: a hand-edited file never loses everything after it.
_mf_strip() {
	awk -v m="$1" '
		$0 == "# BEGIN " m {
			for (i = 1; i <= held; i++) print buf[i]
			held = 1; buf[1] = $0; next
		}
		held && $0 == "# END " m { held = 0; next }
		held { buf[++held] = $0; next }
		{ print }
		END { for (i = 1; i <= held; i++) print buf[i] }'
}

# <marker> [top] — stripped, then the block (body from ENVIRON _MF_BODY, verbatim: awk -v
# would unescape fstab's \040) added first with "top", else before a final exit statement
# (rc.local: nothing after "exit 0" ever runs), else at the end. Machman blocks are not the
# file's own code: older runs appended theirs after that exit, and those (another VM's
# included) stay inert there.
_mf_put() {
	_mf_strip "$1" | awk -v m="$1" -v top="${2:-}" '
		{
			line[++n] = $0
			if ($0 ~ /^# BEGIN machman-/) inb = 1
			ours[n] = inb
			if (inb && $0 ~ /^# END machman-/) inb = 0
		}
		END {
			body = ENVIRON["_MF_BODY"]
			sub(/\n+$/, "", body)
			at = n + 1
			if (top != "") at = 1
			for (i = n; i >= 1 && top == ""; i--) {
				if (ours[i] || line[i] ~ /^[ \t]*(#.*)?$/) continue
				if (line[i] ~ /^[ \t]*exit([ \t;].*)?$/) at = i
				break
			}
			for (i = 1; i < at; i++) print line[i]
			print "# BEGIN " m
			if (body != "") print body
			print "# END " m
			for (i = at; i <= n; i++) print line[i]
		}'
}

# Lines containing ENVIRON _MF_TEXT dropped (no regex: markers and keys are literal).
_mf_drop() {
	awk 'index($0, ENVIRON["_MF_TEXT"]) == 0'
}

# strip_block <file> [marker] — remove "# BEGIN <marker>"…"# END <marker>" (default
# $MARKER). A file without that block is not ours: left untouched, links included. One
# that has it but may not be edited (a link to it, a hard link) is refused by name.
strip_block() {
	_sb_m="${2:-$MARKER}"
	[ -f "$1" ] || return 0
	grep -qxF "# BEGIN $_sb_m" "$1" 2>/dev/null || return 0
	rewrite_file "$1" _mf_strip "$_sb_m"
}

# put_block [-m <mode>] [-o <user:group>] [-t] <file> <marker> <body> — replace that
# marker's block with <body>, first in the file with -t; a missing file is created first
# (-m/-o apply only then).
put_block() {
	_pb_mode=644
	_pb_own=""
	_pb_top=""
	while :; do
		case "$1" in
		-m) _pb_mode="$2"; shift 2 ;;
		-o) _pb_own="$2"; shift 2 ;;
		-t) _pb_top=top; shift ;;
		*) break ;;
		esac
	done
	if [ ! -e "$1" ] && [ ! -L "$1" ]; then
		if [ -n "$_pb_own" ]; then
			write_file -m "$_pb_mode" -o "$_pb_own" "$1" </dev/null || return 1
		else
			write_file -m "$_pb_mode" "$1" </dev/null || return 1
		fi
	fi
	_MF_BODY="$3"
	export _MF_BODY
	_pb_code=0
	rewrite_file "$1" _mf_put "$2" ${_pb_top:+"$_pb_top"} || _pb_code=$?
	unset _MF_BODY
	return "$_pb_code"
}

# drop_lines <file> <text> — remove every line containing <text>. A file without one is
# left untouched (links included); one that has it but may not be edited is refused.
drop_lines() {
	[ -f "$1" ] || return 0
	grep -qF -- "$2" "$1" 2>/dev/null || return 0
	_MF_TEXT="$2"
	export _MF_TEXT
	_dl_code=0
	rewrite_file "$1" _mf_drop || _dl_code=$?
	unset _MF_TEXT
	return "$_dl_code"
}

# Adopt: comment matching UNMARKED lines out, tagged so uninstall can restore them
# exactly. Lines inside our marker block and already-commented lines are left alone.
# supersede_lines <file> <awk ERE>
supersede_lines() {
	[ -f "$1" ] || return 0
	rewrite_file "$1" awk -v re="$2" -v m="$MARKER" '
		$0 == "# BEGIN " m { inb = 1 }
		$0 == "# END " m { inb = 0 }
		!inb && $0 !~ /^#/ && $0 ~ re { print "#" $0 " # " m "-superseded"; next }
		{ print }
	'
}

# Undo supersede_lines: strip the tag and the leading comment mark, restoring the
# original line byte-for-byte.
restore_superseded() {
	[ -f "$1" ] || return 0
	grep -qF -- " # $MARKER-superseded" "$1" 2>/dev/null || return 0
	rewrite_file "$1" sed "/ # ${MARKER}-superseded\$/{s/ # ${MARKER}-superseded\$//;s/^#//;}"
}

# The uninstall's answer to a refusal (R_ERROR): say what stays, carry on with the rest —
# the run ends partial (exit 4).
uninstall_kept() {
	warn "$R_ERROR — its Machman lines stay; remove those tagged $MARKER yourself."
	UNINSTALL_KEPT=1
	return 0
}
