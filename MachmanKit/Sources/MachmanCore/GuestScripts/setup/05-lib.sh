# === machman-setup: 05-lib ===
# Shared helpers (the former machman-lib.sh, inlined by assembly, plus arrow-key menus).
#
# House rules for everything in here and in its callers:
#   * POSIX sh only. NO `local`: macOS ksh93 rejects it outright, so functions namespace
#     their temporaries (_fn_foo) and hand results back through R_* globals.
#   * Every mutation goes through run()/run_live() so it can be narrated (-v), skipped
#     (--dry-run) and, when it fails, blamed on a named step instead of a bare tool error.
#   * Output degrades: colour only when the terminal says so, ASCII glyphs when neither
#     the locale nor the ssh session says UTF-8, numbered prompts when arrow keys cannot
#     work — these scripts are read through serial consoles, ssh sessions and pipes alike.

# ---------------------------------------------------------------------------- state ----

# Callers may set these before or after sourcing; defaults keep the lib usable either way.
: "${VERBOSE:=0}"
: "${QUIET:=0}"
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${INTERACTIVE:=1}"

STEP=""              # what we are doing, for the failure trap
FAILED_STEPS=""      # comma-separated labels of optional steps that did not work out
ERR_LINES=""         # newline-separated "step: message" pairs, for the report's ERROR_N
MACHMAN_DIED=0       # die() already explained the failure; the trap stays quiet
REPORT_DONE=0        # a report was written this run; the trap must not clobber it
R_ERROR=""           # last run() failure's final stderr line
R_LAST_FAILURE=""    # last step_failed() message, for the report's one-sentence note
R_YES=0              # ask_yes_no result
R_INDEX=0            # ask_choice / menu_select result
R_ITEM=""
R_MARKS=""           # menu_multi result: comma list of ON indexes
R_KEY=""             # key_read result

# Styling defaults so `set -u` is safe before (and without) ui_detect.
C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
G_OK="[ok]"; G_RUN="[..]"; G_WARN="[!!]"; G_ERR="[xx]"
G_PTR=">"; G_ON="[x]"; G_OFF="[ ]"
ESC="$(printf '\033')"
CR="$(printf '\r')"

# ----------------------------------------------------------------- terminal + output ----

UI_COLOR=0
UI_UNICODE=0
UI_NAV=0
UI_COLS=80
UI_IN=""             # fd to read answers from, empty when nothing can answer

ui_detect() {
	# Colour: a real tty, a usable TERM, no NO_COLOR — then terminfo when it exists,
	# COLORTERM as a hint, and a TERM-name list last (busybox ships no tput at all).
	# vt100 is deliberately NOT in the list: a real vt100 has no colour, and where tput
	# exists it agrees.
	if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
		if have tput; then
			[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ] && UI_COLOR=1
		elif [ -n "${COLORTERM:-}" ]; then
			UI_COLOR=1
		else
			case "${TERM:-}" in
			*color*|xterm*|screen*|tmux*|linux|ansi|foot*|alacritty|kitty|rxvt*)
				UI_COLOR=1 ;;
			esac
		fi
	fi
	# Unicode: a UTF-8 locale — or a PSEUDO-terminal with a modern TERM. The glyph bytes
	# render on the CONNECTED terminal (an ssh client, tmux, a GUI terminal), which is
	# UTF-8 in practice; only the raw consoles (hvc*, ttyV*, tty1…) stay conservative.
	# The controlling tty's NAME is the escalation-proof signal: doas/sudo strip LANG and
	# every SSH_* variable, but the terminal itself follows the session into root.
	case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*UTF-8*|*utf-8*|*UTF8*|*utf8*) UI_UNICODE=1 ;;
	esac
	if [ "$UI_UNICODE" -eq 0 ]; then
		# The REAL fds, never /dev/tty: ttyname of an fd opened from /dev/tty is just
		# "/dev/tty" again. stdin first; stderr covers a piped stdin.
		_ud_tty="$(tty 2>/dev/null)" || _ud_tty=""
		[ -n "$_ud_tty" ] || { _ud_tty="$( (tty <&2) 2>/dev/null)" || _ud_tty=""; }
		case "$_ud_tty" in
		/dev/pts/*|/dev/ttyp*|/dev/ttys[0-9]*)   # Linux/FreeBSD pts, OpenBSD ttyp, macOS ttys
			case "${TERM:-}" in
			xterm*|screen*|tmux*|*256color*|foot*|alacritty|kitty|rxvt*) UI_UNICODE=1 ;;
			esac
			;;
		esac
	fi
	UI_COLS="$( (have tput && tput cols) 2>/dev/null || true )"
	[ -n "$UI_COLS" ] || UI_COLS="$( (stty size 2>/dev/null | cut -d' ' -f2) || true )"
	[ -n "$UI_COLS" ] || UI_COLS="${COLUMNS:-80}"
	case "$UI_COLS" in
	''|*[!0-9]*) UI_COLS=80 ;;
	esac
	[ "$UI_COLS" -ge 40 ] || UI_COLS=80

	if [ "$UI_COLOR" -eq 1 ]; then
		C_RESET="$(printf '\033[0m')"
		C_DIM="$(printf '\033[2m')"
		C_BOLD="$(printf '\033[1m')"
		C_RED="$(printf '\033[31m')"
		C_GREEN="$(printf '\033[32m')"
		C_YELLOW="$(printf '\033[33m')"
		C_CYAN="$(printf '\033[36m')"
	else
		C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
	fi
	if [ "$UI_UNICODE" -eq 1 ]; then
		G_OK="✓"; G_RUN="→"; G_WARN="!"; G_ERR="✗"; G_PTR="❯"; G_ON="◉"; G_OFF="○"
	else
		G_OK="[ok]"; G_RUN="[..]"; G_WARN="[!!]"; G_ERR="[xx]"
		G_PTR=">"; G_ON="[x]"; G_OFF="[ ]"
	fi

	# Where interactive answers come from: the controlling terminal if there is one (so a
	# piped stdin still prompts), else stdin, else nothing — and then we never ask. The
	# open is probed in a subshell first: /dev/tty exists and looks readable even when
	# there is no controlling terminal, and the failed exec would print through our
	# redirect.
	if [ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
		exec 3</dev/tty
		UI_IN=3
	elif [ -t 0 ]; then
		exec 3<&0
		UI_IN=3
	else
		INTERACTIVE=0
	fi
	[ "$ASSUME_YES" -eq 1 ] && INTERACTIVE=0

	# Arrow-key menus: raw byte reads (stty+dd on the answer fd) plus line redraws with
	# vt100-era codes. Works on serial consoles too; TERM=dumb and pipes fall back to
	# numbered prompts.
	if [ "$INTERACTIVE" -eq 1 ] && [ -n "$UI_IN" ] && [ -t 1 ] \
		&& [ "${TERM:-dumb}" != "dumb" ] && have stty && have dd \
		&& stty -g <&3 >/dev/null 2>&1; then
		UI_NAV=1
	fi
	return 0
}

have() {
	command -v "$1" >/dev/null 2>&1
}

wrap() {
	if have fold; then
		printf '%s\n' "$1" | fold -s -w "$((UI_COLS - 2))"
	else
		printf '%s\n' "$1"
	fi
}

say() {
	[ "$QUIET" -eq 1 ] && return 0
	wrap "$1"
}

ok() {
	[ "$QUIET" -eq 1 ] && return 0
	wrap "${C_GREEN}${G_OK}${C_RESET} $1"
}

acting() {
	[ "$QUIET" -eq 1 ] && return 0
	wrap "${G_RUN} $1"
}

warn() {
	wrap "${C_YELLOW}${G_WARN}${C_RESET} $1" >&2
}

note() {
	[ "$QUIET" -eq 1 ] && return 0
	wrap "${C_DIM}   $1${C_RESET}"
}

verbose() {
	[ "$VERBOSE" -eq 1 ] || return 0
	wrap "${C_DIM}[$1]${C_RESET} $2"
}

# die <exit-code> <what went wrong> [what to do about it]
# One precise sentence, then the remedy. Nothing else is allowed to end this script.
die() {
	MACHMAN_DIED=1
	wrap "${C_RED}${G_ERR}${C_RESET} $2" >&2
	[ -n "${3:-}" ] && wrap "   $3" >&2
	exit "$1"
}

# Record an optional step that failed: the run continues, the report says what was missed.
step_failed() {
	if [ -z "$FAILED_STEPS" ]; then
		FAILED_STEPS="$1"
	elif ! { printf '%s' ",$FAILED_STEPS," | grep -q ",$1,"; }; then
		FAILED_STEPS="$FAILED_STEPS,$1"
	fi
	[ -z "$R_LAST_FAILURE" ] && R_LAST_FAILURE="$2"
	if [ -z "$ERR_LINES" ]; then
		ERR_LINES="$1: $2"
	else
		ERR_LINES="$ERR_LINES
$1: $2"
	fi
	warn "$2"
	[ -n "${3:-}" ] && note "$3"
	return 0
}

# The backstop: any abort that did not go through die() still names its step. Callers pass
# the exit status they were entered with.
machman_exit_trap() {
	if [ "$1" -ne 0 ] && [ "$MACHMAN_DIED" -eq 0 ]; then
		wrap "${C_RED}${G_ERR}${C_RESET} unexpected failure during: ${STEP:-startup}" >&2
		wrap "   exit $1. Re-run with -v to see every step." >&2
	fi
	exit "$1"
}

# ------------------------------------------------------------------------ running ----

# run <label> <cmd> [args…] — output captured (quiet unless -v or a failure).
run() {
	STEP="$1"
	shift
	verbose run "$*"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would $STEP:  $*"
		return 0
	fi
	if _run_out="$("$@" 2>&1)"; then
		[ -n "$_run_out" ] && verbose out "$_run_out"
		return 0
	fi
	_run_code=$?
	R_ERROR="$(printf '%s' "$_run_out" | tail -n 1)"
	return "$_run_code"
}

# run_live <label> <cmd> [args…] — for slow or chatty commands (package installs, rebuilds)
# where hiding the output would look like a hang.
run_live() {
	STEP="$1"
	shift
	verbose run "$*"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would $STEP:  $*"
		return 0
	fi
	acting "$STEP"
	"$@"
}

# ------------------------------------------------------------------------ prompts ----

# ask_yes_no <question> <default: y|n> → R_YES=1|0
ask_yes_no() {
	_ayn_hint="[y/N]"
	[ "$2" = "y" ] && _ayn_hint="[Y/n]"
	if [ "$INTERACTIVE" -eq 0 ] || [ -z "$UI_IN" ]; then
		[ "$2" = "y" ] && R_YES=1 || R_YES=0
		verbose ask "$1 → ${2} (not interactive)"
		return 0
	fi
	_ayn_tries=0
	while [ "$_ayn_tries" -lt 3 ]; do
		printf '%s %s ' "$1" "$_ayn_hint"
		if ! read -r _ayn_answer <&3; then
			printf '\n'
			die 3 "no answer — cancelled." "Re-run with the matching option to decide up front."
		fi
		case "$_ayn_answer" in
		y|Y|yes|YES) R_YES=1; return 0 ;;
		n|N|no|NO) R_YES=0; return 0 ;;
		q|Q) die 3 "cancelled — nothing was changed." ;;
		"") [ "$2" = "y" ] && R_YES=1 || R_YES=0; return 0 ;;
		esac
		_ayn_tries=$((_ayn_tries + 1))
	done
	die 3 "no usable answer to: $1" "Answer y or n, or pass the option instead."
}

# ask_choice <question> <items, one per line> <default index> → R_INDEX, R_ITEM
# The numbered fallback; menu_select prefers arrows and calls this when they cannot work.
ask_choice() {
	_ac_items="$2"
	_ac_default="$3"
	_ac_count=0
	_ac_old_ifs="$IFS"
	IFS='
'
	# shellcheck disable=SC2086
	set -- $_ac_items
	IFS="$_ac_old_ifs"
	_ac_count=$#
	[ "$_ac_count" -gt 0 ] || die 3 "nothing to choose from for: $1"
	if [ "$_ac_count" -eq 1 ]; then
		R_INDEX=1
		R_ITEM="$1"
		return 0
	fi
	if [ "$INTERACTIVE" -eq 0 ] || [ -z "$UI_IN" ]; then
		R_INDEX="$_ac_default"
		R_ITEM="$(printf '%s\n' "$_ac_items" | sed -n "${_ac_default}p")"
		verbose ask "auto-picked #$R_INDEX ($R_ITEM)"
		return 0
	fi
	say ""
	say "$1"
	say ""
	_ac_i=1
	for _ac_item in "$@"; do
		printf '  %s) %s\n' "$_ac_i" "$_ac_item"
		_ac_i=$((_ac_i + 1))
	done
	say ""
	_ac_tries=0
	while [ "$_ac_tries" -lt 3 ]; do
		printf 'Choose [%s]: ' "$_ac_default"
		if ! read -r _ac_answer <&3; then
			printf '\n'
			die 3 "no answer — cancelled." "Pass the matching option to decide up front."
		fi
		[ -z "$_ac_answer" ] && _ac_answer="$_ac_default"
		case "$_ac_answer" in
		q|Q) die 3 "cancelled — nothing was changed." ;;
		''|*[!0-9]*) ;;
		*)
			if [ "$_ac_answer" -ge 1 ] && [ "$_ac_answer" -le "$_ac_count" ]; then
				R_INDEX="$_ac_answer"
				_ac_i=1
				for _ac_item in "$@"; do
					if [ "$_ac_i" -eq "$_ac_answer" ]; then
						R_ITEM="$_ac_item"
						return 0
					fi
					_ac_i=$((_ac_i + 1))
				done
			fi
			;;
		esac
		warn "pick a number between 1 and $_ac_count (or q to cancel)"
		_ac_tries=$((_ac_tries + 1))
	done
	die 3 "no usable answer to: $1" "Pass the matching option instead."
}

# --------------------------------------------------------------------- raw key input ----

RAW_SAVED=""

raw_on() {
	RAW_SAVED="$(stty -g <&3)"
	stty -icanon -echo min 1 time 0 <&3
	printf '\033[?25l'
	return 0
}

raw_off() {
	[ -n "$RAW_SAVED" ] && stty "$RAW_SAVED" <&3 2>/dev/null
	RAW_SAVED=""
	printf '\033[?25h'
	return 0
}

# key_read → R_KEY: up|down|enter|space|quit|digit:<d>|other. Bare ESC is separated from
# a sequence by giving the follow-up bytes ~0.2 s to arrive (stty min 0 time 2).
key_read() {
	R_KEY=other
	_kr_c="$(dd bs=1 count=1 2>/dev/null <&3)" || { R_KEY=quit; return 0; }
	case "$_kr_c" in
	"$ESC")
		stty min 0 time 2 <&3 2>/dev/null
		_kr_b="$(dd bs=1 count=1 2>/dev/null <&3)"
		_kr_l="$(dd bs=1 count=1 2>/dev/null <&3)"
		stty min 1 time 0 <&3 2>/dev/null
		if [ -z "$_kr_b" ]; then
			R_KEY=quit
		else
			case "$_kr_b$_kr_l" in
			"[A"|"OA") R_KEY=up ;;
			"[B"|"OB") R_KEY=down ;;
			esac
		fi
		;;
	""|"$CR") R_KEY=enter ;;
	" ") R_KEY=space ;;
	q|Q) R_KEY=quit ;;
	k) R_KEY=up ;;
	j) R_KEY=down ;;
	[0-9]) R_KEY="digit:$_kr_c" ;;
	esac
	return 0
}

# ------------------------------------------------------------------------ arrow menus ----

# menu_draw <highlight> <marks or "-"> <items…>  (marks: comma list of ON indexes)
menu_draw() {
	_md_hi="$1"; _md_marks="$2"; shift 2
	_md_i=1
	for _md_it in "$@"; do
		printf '\r\033[K'
		_md_mark=""
		if [ "$_md_marks" != "-" ]; then
			case ",$_md_marks," in
			*",$_md_i,"*) _md_mark="$G_ON " ;;
			*) _md_mark="$G_OFF " ;;
			esac
		fi
		if [ "$_md_i" -eq "$_md_hi" ]; then
			printf '  %s%s %s%s%s\n' "${C_BOLD}${C_CYAN}" "$G_PTR" "$_md_mark" "$_md_it" \
				"$C_RESET"
		else
			printf '    %s%s%s%s\n' "$C_DIM" "$_md_mark" "$_md_it" "$C_RESET"
		fi
		_md_i=$((_md_i + 1))
	done
	return 0
}

toggle_mark() { # <marks> <index> → R_MARKS
	case ",$1," in
	*",$2,"*) R_MARKS="$(printf '%s' ",$1," | sed "s/,$2,/,/" | sed 's/^,//; s/,$//')" ;;
	*) [ -n "$1" ] && R_MARKS="$1,$2" || R_MARKS="$2" ;;
	esac
	return 0
}

# menu_select <question> <items, one per line> <default index> → R_INDEX, R_ITEM
# ask_choice with arrows where they work; identical result contract.
menu_select() {
	if [ "$UI_NAV" -ne 1 ]; then
		ask_choice "$1" "$2" "$3"
		return 0
	fi
	_ms_q="$1"; _ms_hi="$3"
	_ms_old_ifs="$IFS"
	IFS='
'
	# shellcheck disable=SC2086
	set -- $2
	IFS="$_ms_old_ifs"
	_ms_n=$#
	[ "$_ms_n" -gt 0 ] || die 3 "nothing to choose from for: $_ms_q"
	if [ "$_ms_n" -eq 1 ]; then
		R_INDEX=1
		R_ITEM="$1"
		return 0
	fi
	printf '%s%s%s  %s(arrows, enter)%s\n' "$C_BOLD" "$_ms_q" "$C_RESET" "$C_DIM" "$C_RESET"
	raw_on
	trap 'raw_off; exit 130' INT
	menu_draw "$_ms_hi" "-" "$@"
	while :; do
		printf '\033[%dA' "$_ms_n"
		key_read
		case "$R_KEY" in
		up) _ms_hi=$(( _ms_hi > 1 ? _ms_hi - 1 : _ms_n )) ;;
		down) _ms_hi=$(( _ms_hi < _ms_n ? _ms_hi + 1 : 1 )) ;;
		digit:*)
			_ms_d="${R_KEY#digit:}"
			if [ "$_ms_d" -ge 1 ] && [ "$_ms_d" -le "$_ms_n" ]; then
				_ms_hi="$_ms_d"
				menu_draw "$_ms_hi" "-" "$@"
				break
			fi
			;;
		enter) menu_draw "$_ms_hi" "-" "$@"; break ;;
		quit)
			menu_draw "$_ms_hi" "-" "$@"
			raw_off
			trap - INT
			die 3 "cancelled — nothing was changed."
			;;
		esac
		menu_draw "$_ms_hi" "-" "$@"
	done
	raw_off
	trap - INT
	R_INDEX="$_ms_hi"
	_ms_i=1
	for _ms_it in "$@"; do
		[ "$_ms_i" -eq "$_ms_hi" ] && R_ITEM="$_ms_it"
		_ms_i=$((_ms_i + 1))
	done
	return 0
}

# menu_multi <question> <items, one per line> <default ON indexes: "1,3"> → R_MARKS
# Space toggles, digits toggle, enter confirms. Falls back to a one-shot numbered toggle
# prompt when arrows cannot work; non-interactive keeps the defaults.
menu_multi() {
	_mm_q="$1"; _mm_items="$2"; _mm_marks="$3"
	_mm_old_ifs="$IFS"
	IFS='
'
	# shellcheck disable=SC2086
	set -- $_mm_items
	IFS="$_mm_old_ifs"
	_mm_n=$#
	[ "$_mm_n" -gt 0 ] || { R_MARKS="$_mm_marks"; return 0; }
	if [ "$UI_NAV" -ne 1 ]; then
		if [ "$INTERACTIVE" -eq 0 ] || [ -z "$UI_IN" ]; then
			R_MARKS="$_mm_marks"
			verbose ask "$_mm_q → kept [$_mm_marks] (not interactive)"
			return 0
		fi
		say ""
		say "$_mm_q"
		say ""
		_mm_i=1
		for _mm_it in "$@"; do
			case ",$_mm_marks," in
			*",$_mm_i,"*) printf '  %s) %s %s\n' "$_mm_i" "$G_ON" "$_mm_it" ;;
			*) printf '  %s) %s %s\n' "$_mm_i" "$G_OFF" "$_mm_it" ;;
			esac
			_mm_i=$((_mm_i + 1))
		done
		say ""
		printf 'Toggle numbers (space-separated), empty keeps the selection: '
		read -r _mm_answer <&3 || _mm_answer=""
		for _mm_t in $_mm_answer; do
			case "$_mm_t" in
			''|*[!0-9]*) continue ;;
			esac
			if [ "$_mm_t" -ge 1 ] && [ "$_mm_t" -le "$_mm_n" ]; then
				toggle_mark "$_mm_marks" "$_mm_t"
				_mm_marks="$R_MARKS"
			fi
		done
		R_MARKS="$_mm_marks"
		return 0
	fi
	_mm_hi=1
	printf '%s%s%s  %s(arrows, space toggles, enter)%s\n' \
		"$C_BOLD" "$_mm_q" "$C_RESET" "$C_DIM" "$C_RESET"
	raw_on
	trap 'raw_off; exit 130' INT
	menu_draw "$_mm_hi" "${_mm_marks:-none}" "$@"
	while :; do
		printf '\033[%dA' "$_mm_n"
		key_read
		case "$R_KEY" in
		up) _mm_hi=$(( _mm_hi > 1 ? _mm_hi - 1 : _mm_n )) ;;
		down) _mm_hi=$(( _mm_hi < _mm_n ? _mm_hi + 1 : 1 )) ;;
		space)
			toggle_mark "$_mm_marks" "$_mm_hi"
			_mm_marks="$R_MARKS"
			;;
		digit:*)
			_mm_d="${R_KEY#digit:}"
			if [ "$_mm_d" -ge 1 ] && [ "$_mm_d" -le "$_mm_n" ]; then
				toggle_mark "$_mm_marks" "$_mm_d"
				_mm_marks="$R_MARKS"
			fi
			;;
		enter) menu_draw "$_mm_hi" "${_mm_marks:-none}" "$@"; break ;;
		quit)
			menu_draw "$_mm_hi" "${_mm_marks:-none}" "$@"
			raw_off
			trap - INT
			die 3 "cancelled — nothing was changed."
			;;
		esac
		menu_draw "$_mm_hi" "${_mm_marks:-none}" "$@"
	done
	raw_off
	trap - INT
	R_MARKS="$_mm_marks"
	return 0
}

# ------------------------------------------------------------------- marked-file edits ----

# Remove the lines between "# BEGIN <marker>" and "# END <marker>" (both inclusive).
strip_block() {
	[ -f "$1" ] || return 0
	_sb_tmp="$1.machman-tmp"
	awk -v m="$MARKER" '
		$0 == "# BEGIN " m { skip = 1; next }
		$0 == "# END " m { skip = 0; next }
		!skip { print }
	' "$1" > "$_sb_tmp"
	mv "$_sb_tmp" "$1"
	return 0
}

# Adopt: comment matching UNMARKED lines out, tagged so uninstall can restore them
# exactly. Lines inside our marker block and already-commented lines are left alone.
# supersede_lines <file> <awk ERE>
supersede_lines() {
	[ -f "$1" ] || return 0
	_sl_tmp="$1.machman-tmp"
	awk -v re="$2" -v m="$MARKER" '
		$0 == "# BEGIN " m { inb = 1 }
		$0 == "# END " m { inb = 0 }
		!inb && $0 !~ /^#/ && $0 ~ re { print "#" $0 " # " m "-superseded"; next }
		{ print }
	' "$1" > "$_sl_tmp"
	mv "$_sl_tmp" "$1"
	return 0
}

# Undo supersede_lines: strip the tag and the leading comment mark, restoring the
# original line byte-for-byte.
restore_superseded() {
	[ -f "$1" ] || return 0
	_rs_tmp="$1.machman-tmp"
	sed "/ # ${MARKER}-superseded\$/{s/ # ${MARKER}-superseded\$//;s/^#//;}" \
		"$1" > "$_rs_tmp"
	mv "$_rs_tmp" "$1"
	return 0
}
