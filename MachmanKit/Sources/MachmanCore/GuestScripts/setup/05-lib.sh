# === machman-setup: 05-lib ===
# Shared helpers (the former machman-lib.sh, inlined by assembly): state, output, run and the
# prompts. The arrow-key menus are 06-menus, the link-safe file edits 07-files.
#
# House rules for everything in here and in its callers:
#   * POSIX sh only. NO `local`: macOS ksh93 rejects it outright, so functions namespace
#     their temporaries (_fn_foo) and hand results back through R_* globals.
#   * Every mutation goes through run()/run_live() so it can be narrated (-v), skipped
#     (--dry-run) and, when it fails, blamed on a named step instead of a bare tool error.
#   * Output degrades: colour only when the terminal says so, ASCII glyphs and prose when
#     neither the locale nor the ssh session says UTF-8, numbered prompts when arrow keys
#     cannot work — these scripts are read through serial consoles, ssh sessions and pipes
#     alike.

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
NOTE_LINES=""        # the same for its NOTE_N: informational, never a failure
MACHMAN_DIED=0       # die() already explained the failure; the trap stays quiet
REPORT_DONE=0        # a report was written this run; the trap must not clobber it
UNINSTALL_KEPT=0     # the uninstall had to leave Machman lines in a file it may not edit
R_ERROR=""           # last run() failure's final stderr line
R_LAST_FAILURE=""    # last step_failed() message, for the report's one-sentence note
R_YES=0              # ask_yes_no result
R_INDEX=0            # ask_choice / menu_select result
R_ITEM=""
R_MARKS=""           # menu_multi result: comma list of ON indexes
R_KEY=""             # key_read result
R_MOUNT_WHAT=""      # sshfsauto_entry results: source and mountpoint, two slots —
R_MOUNT_WHERE=""     # host paths carry spaces, so they are never packed into one
R_TEXT=""            # ascii_of result
R_MADE=0             # make_dir result: 1 when the directory itself is new

# Styling defaults so `set -u` is safe before (and without) ui_detect.
C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
G_OK="[ok]"; G_RUN="[..]"; G_WARN="[!!]"; G_ERR="[xx]"
G_PTR=">"; G_ON="[x]"; G_OFF="[ ]"; G_SEP="-"
G_MARK_W=3           # G_ON's and G_OFF's columns: the shells and awks count bytes
ESC="$(printf '\033')"
CR="$(printf '\r')"

# ----------------------------------------------------------------- terminal + output ----

UI_COLOR=0
UI_UNICODE=0
UI_ASCII=0           # 1 once ui_detect gave the terminal ASCII glyphs: prose follows them
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
		G_SEP="·"; G_MARK_W=1
		UI_ASCII=0
	else
		G_OK="[ok]"; G_RUN="[..]"; G_WARN="[!!]"; G_ERR="[xx]"
		G_PTR=">"; G_ON="[x]"; G_OFF="[ ]"; G_SEP="-"; G_MARK_W=3
		UI_ASCII=1
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

# sh_quote <value> — the value as ONE sh word for embedding in generated scripts.
# Plain '%s' breaks on the first apostrophe (VM names and host paths are user text);
# closing, escaping and reopening ('\'') survives any content.
sh_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ascii_of <text> → R_TEXT: what a terminal shows of the script's own text — on an ASCII one
# (UI_ASCII) its em dashes, arrows, middle dots and ellipses spelled in ASCII, else the
# text as it is (no fork). Every printer goes through here; reports and state keep the text
# as written.
ascii_of() {
	R_TEXT="$1"
	[ "$UI_ASCII" -eq 1 ] || return 0
	R_TEXT="$(printf '%s\n' "$1" | LC_ALL=C sed 's/—/-/g; s/→/->/g; s/·/-/g; s/…/.../g')"
	return 0
}

wrap() {
	ascii_of "$1"
	if have fold; then
		printf '%s\n' "$R_TEXT" | fold -s -w "$((UI_COLS - 2))"
	else
		printf '%s\n' "$R_TEXT"
	fi
}

# wrap_hanging <prefix> <its columns> <text> — <text> folded like wrap, after <prefix> on
# its first line and indented under it on the rest (a plan value under its column, a menu
# item's text under its number); a multi-line <text>'s lines too, folded or not. The caller
# says how wide the prefix is: a glyph in it is more bytes than columns, and dash and most
# awks count bytes.
wrap_hanging() {
	ascii_of "$3"
	_wh_w=$((UI_COLS - 2 - $2))
	[ "$_wh_w" -ge 20 ] || _wh_w=20
	if have fold; then
		printf '%s\n' "$R_TEXT" | fold -s -w "$_wh_w"
	else
		printf '%s\n' "$R_TEXT"
	fi | awk -v p="$1" -v n="$2" '
		{ sub(/ +$/, "") }
		NR == 1 { print p $0; next }
		{ printf "%" n "s%s\n", "", $0 }'
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

# Something the report must mention that is no failed step (a repair, a disabled hook):
# said now and reported as a NOTE_ line — the inspector lists it under Notes, never under
# Errors — while the run's status stays what its steps make it. report_note <step> <message>
report_note() {
	if [ -z "$NOTE_LINES" ]; then
		NOTE_LINES="$1: $2"
	else
		NOTE_LINES="$NOTE_LINES
$1: $2"
	fi
	warn "$2"
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
	else
		# Captured INSIDE the else arm: after `fi`, $? is the if-statement's own status,
		# which POSIX defines as 0 when no branch ran — reading it there turns every
		# failure into success and disarms all `run … || step_failed` callers.
		_run_code=$?
	fi
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
	# Folded like everything said, the answer going after the hint on its last line.
	_ayn_text="$(wrap "$1 $_ayn_hint")"
	_ayn_tries=0
	while [ "$_ayn_tries" -lt 3 ]; do
		printf '%s ' "$_ayn_text"
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
	# The question first: `set --` below hands the positional parameters to the items.
	_ac_q="$1"
	_ac_items="$2"
	_ac_default="$3"
	_ac_count=0
	_ac_old_ifs="$IFS"
	IFS='
'
	# shellcheck disable=SC2086
	set -f
	set -- $_ac_items
	set +f
	IFS="$_ac_old_ifs"
	_ac_count=$#
	[ "$_ac_count" -gt 0 ] || die 3 "nothing to choose from for: $_ac_q"
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
	say "$_ac_q"
	say ""
	_ac_i=1
	for _ac_item in "$@"; do
		# Items may be "title<TAB>note" pairs (the arrow menus' format): flatten here.
		wrap_hanging "  $_ac_i) " "$((${#_ac_i} + 4))" \
			"$(printf '%s' "$_ac_item" | tr '	' ' ')"
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
	die 3 "no usable answer to: $_ac_q" "Pass the matching option instead."
}
