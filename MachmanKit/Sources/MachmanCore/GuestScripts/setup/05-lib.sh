# === machman-setup: 05-lib ===
# Shared helpers (the former machman-lib.sh, inlined by assembly, plus arrow-key menus).
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

# Styling defaults so `set -u` is safe before (and without) ui_detect.
C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
G_OK="[ok]"; G_RUN="[..]"; G_WARN="[!!]"; G_ERR="[xx]"
G_PTR=">"; G_ON="[x]"; G_OFF="[ ]"; G_SEP="-"
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
		G_SEP="·"
		UI_ASCII=0
	else
		G_OK="[ok]"; G_RUN="[..]"; G_WARN="[!!]"; G_ERR="[xx]"
		G_PTR=">"; G_ON="[x]"; G_OFF="[ ]"; G_SEP="-"
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

# wrap_hanging <prefix> <text> — <text> folded like wrap, after <prefix> on its first line
# and indented under it on the rest (a plan value under its column, a menu item's text
# under its number); a multi-line <text>'s lines too.
wrap_hanging() {
	ascii_of "$2"
	_wh_w=$((UI_COLS - 2 - ${#1}))
	[ "$_wh_w" -ge 20 ] || _wh_w=20
	if have fold; then
		printf '%s\n' "$R_TEXT" | fold -s -w "$_wh_w" | awk -v p="$1" '
			{ sub(/ +$/, "") }
			NR == 1 { print p $0; next }
			{ printf "%" length(p) "s%s\n", "", $0 }'
	else
		printf '%s%s\n' "$1" "$R_TEXT"
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
		wrap_hanging "  $_ac_i) " "$(printf '%s' "$_ac_item" | tr '	' ' ')"
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
# Items are "title<TAB>note" pairs (the note is optional). Titles pad to one shared
# column so the notes align; notes are dim and clipped to the terminal so a row never
# wraps (the redraw's cursor math counts one line per item). Marks color by state —
# green on, dim off — unmarked titles are dim, and the cursor row is bold with a cyan
# pointer.
menu_draw() {
	_md_hi="$1"; _md_marks="$2"; shift 2
	# The mark's own columns ("◉ " is 2, "[x] " 4): a note stops at the console's edge.
	_md_mw=0
	[ "$_md_marks" != "-" ] && _md_mw=$((${#G_ON} + 1))
	_md_w=0
	for _md_it in "$@"; do
		ascii_of "$_md_it"
		_md_t="${R_TEXT%%	*}"
		[ "${#_md_t}" -gt "$_md_w" ] && _md_w="${#_md_t}"
	done
	[ "$_md_w" -gt 30 ] && _md_w=30
	_md_i=1
	for _md_it in "$@"; do
		printf '\r\033[K'
		ascii_of "$_md_it"
		_md_it="$R_TEXT"
		_md_t="${_md_it%%	*}"
		_md_note=""
		case "$_md_it" in
		*"	"*) _md_note="${_md_it#*	}" ;;
		esac
		_md_on=0
		if [ "$_md_marks" != "-" ]; then
			case ",$_md_marks," in
			*",$_md_i,"*) _md_on=1 ;;
			esac
		fi
		_md_mark=""
		if [ "$_md_marks" != "-" ]; then
			if [ "$_md_on" -eq 1 ]; then
				_md_mark="${C_GREEN}${G_ON}${C_RESET} "
			else
				_md_mark="${C_DIM}${G_OFF}${C_RESET} "
			fi
		fi
		if [ "$_md_i" -eq "$_md_hi" ]; then
			_md_pre="  ${C_BOLD}${C_CYAN}${G_PTR}${C_RESET} "
			_md_title="${C_BOLD}${_md_t}${C_RESET}"
		elif [ "$_md_marks" != "-" ] && [ "$_md_on" -eq 0 ]; then
			_md_pre="    "
			_md_title="${C_DIM}${_md_t}${C_RESET}"
		else
			_md_pre="    "
			_md_title="$_md_t"
		fi
		_md_tail=""
		if [ -n "$_md_note" ]; then
			_md_room=$((UI_COLS - 6 - _md_mw - _md_w))
			if [ "$_md_room" -lt 8 ]; then
				_md_note=""
			elif [ "${#_md_note}" -gt "$_md_room" ]; then
				_md_note="$(printf '%s' "$_md_note" \
					| awk -v n="$_md_room" '{ print substr($0, 1, n) }')"
			fi
		fi
		if [ -n "$_md_note" ]; then
			_md_k=$((_md_w - ${#_md_t} + 2))
			[ "$_md_k" -lt 1 ] && _md_k=1
			_md_sp=""
			while [ "$_md_k" -gt 0 ]; do
				_md_sp="$_md_sp "
				_md_k=$((_md_k - 1))
			done
			_md_tail="${_md_sp}${C_DIM}${_md_note}${C_RESET}"
		fi
		printf '%s%s%s%s\n' "$_md_pre" "$_md_mark" "$_md_title" "$_md_tail"
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
	set -f
	set -- $2
	set +f
	IFS="$_ms_old_ifs"
	_ms_n=$#
	[ "$_ms_n" -gt 0 ] || die 3 "nothing to choose from for: $_ms_q"
	if [ "$_ms_n" -eq 1 ]; then
		R_INDEX=1
		R_ITEM="$1"
		return 0
	fi
	ascii_of "$_ms_q"
	printf '%s%s%s  %s(arrows, enter)%s\n' "$C_BOLD" "$R_TEXT" "$C_RESET" "$C_DIM" "$C_RESET"
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
	set -f
	set -- $_mm_items
	set +f
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
			_mm_flat="$(printf '%s' "$_mm_it" | tr '	' ' ')"
			case ",$_mm_marks," in
			*",$_mm_i,"*) wrap_hanging "  $_mm_i) $G_ON " "$_mm_flat" ;;
			*) wrap_hanging "  $_mm_i) $G_OFF " "$_mm_flat" ;;
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
	ascii_of "$_mm_q"
	printf '%s%s%s  %s(arrows, space toggles, enter)%s\n' \
		"$C_BOLD" "$R_TEXT" "$C_RESET" "$C_DIM" "$C_RESET"
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
