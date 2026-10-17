# === machman-setup: 06-menus ===
# Raw key input and the arrow-key menus the prompts use where the terminal can take them
# (05-lib's house rules hold here too).

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
	[ "$_md_marks" != "-" ] && _md_mw=$((G_MARK_W + 1))
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
			_mm_cols=$((${#_mm_i} + G_MARK_W + 5))
			case ",$_mm_marks," in
			*",$_mm_i,"*) wrap_hanging "  $_mm_i) $G_ON " "$_mm_cols" "$_mm_flat" ;;
			*) wrap_hanging "  $_mm_i) $G_OFF " "$_mm_cols" "$_mm_flat" ;;
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
