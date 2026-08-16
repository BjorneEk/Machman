# Machman guest-script helpers — sourced by the installer payloads, never run directly.
#
# House rules for everything in here and in its callers:
#   * POSIX sh only. NO `local`: macOS ksh93 rejects it outright, so functions namespace
#     their temporaries (_fn_foo) and hand results back through R_* globals.
#   * Every mutation goes through run()/run_live() so it can be narrated (-v), skipped
#     (--dry-run) and, when it fails, blamed on a named step instead of a bare tool error.
#   * Output degrades: colour only when the terminal says so, ASCII glyphs when the locale
#     is not UTF-8 — these scripts are often read through a serial console.

# ---------------------------------------------------------------------------- state ----

# Callers may set these before or after sourcing; defaults keep the lib usable either way.
: "${VERBOSE:=0}"
: "${QUIET:=0}"
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${INTERACTIVE:=1}"

STEP=""              # what we are doing, for the failure trap
FAILED_STEPS=""      # comma-separated labels of optional steps that did not work out
MACHMAN_DIED=0       # die() already explained the failure; the trap stays quiet
R_ERROR=""           # last run() failure's final stderr line
R_LAST_FAILURE=""    # last step_failed() message, for the report's one-sentence note
R_YES=0              # ask_yes_no result
R_INDEX=0            # ask_choice result
R_ITEM=""

# Styling defaults so `set -u` is safe before (and without) ui_detect.
C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
G_OK="[ok]"; G_RUN="[..]"; G_WARN="[!!]"; G_ERR="[xx]"

# ----------------------------------------------------------------- terminal + output ----

UI_COLOR=0
UI_UNICODE=0
UI_COLS=80
UI_IN=""             # fd to read answers from, empty when nothing can answer

ui_detect() {
	# Colour: a real tty, a usable TERM, no NO_COLOR, and terminfo agreeing when it exists
	# (busybox images ship no tput at all).
	if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
		if have tput; then
			[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ] && UI_COLOR=1
		else
			case "${TERM:-}" in
			*color*|xterm*|screen*|tmux*|vt100|vt220|linux|ansi) UI_COLOR=1 ;;
			esac
		fi
	fi
	case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*UTF-8*|*utf-8*|*UTF8*|*utf8*) UI_UNICODE=1 ;;
	esac
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
	else
		C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
	fi
	if [ "$UI_UNICODE" -eq 1 ]; then
		G_OK="✓"; G_RUN="→"; G_WARN="!"; G_ERR="✗"
	else
		G_OK="[ok]"; G_RUN="[..]"; G_WARN="[!!]"; G_ERR="[xx]"
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
	else
		FAILED_STEPS="$FAILED_STEPS,$1"
	fi
	[ -z "$R_LAST_FAILURE" ] && R_LAST_FAILURE="$2"
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
# Items are shown verbatim, numbered; the caller keeps whatever structure it needs in the
# line itself (first field first, so awk can pick it back out).
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
