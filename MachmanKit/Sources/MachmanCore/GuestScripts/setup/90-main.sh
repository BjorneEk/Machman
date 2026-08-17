# === machman-setup: 90-main ===
# The driver. Feature modules present one interface — <f>_detect, <f>_available,
# <f>_decide, <f>_plan, <f>_act, <f>_report, <f>_uninstall — and this file only ever
# loops the registry, so the next feature is a module and a registry entry, not an edit
# here. Flow: detect → select → decide → preflight → confirm → act → state → report.

FEATURES="console kernelconsole ssh reverse sshfs vfsauto sshfsauto"
SELECTED_FEATURES=""

feature_title() {
	case "$1" in
	console) echo "Console logins" ;;
	kernelconsole) echo "Kernel console output" ;;
	ssh) echo "SSH (Mac -> guest)" ;;
	reverse) echo "Guest -> host SSH" ;;
	sshfs) echo "sshfs (mount host folders)" ;;
	vfsauto) echo "Automount the share (virtiofs)" ;;
	sshfsauto) echo "Automount sshfs folders" ;;
	esac
}

plan_line() {
	[ "$QUIET" -eq 1 ] && return 0
	printf '  %-16s %s\n' "$1" "$2"
	return 0
}

feature_selected() {
	has_word "$1" "$SELECTED_FEATURES"
}

# ------------------------------------------------------------------------- detection ----

if [ "$(id -u)" -ne 0 ]; then
	if [ "$DRY_RUN" -eq 1 ]; then
		warn "not running as root — the plan below is what a real run would do, and some"
		warn "checks (service state) may read as unknown."
	else
		die 3 "this script has to run as root." \
			"Use:  sudo sh install.sh  (or doas, or a root shell)"
	fi
fi

detect_os
detect_init
detect_transport
find_addresses
read_state
read_mounts_list
for _mm_f in $FEATURES; do
	"${_mm_f}_detect"
	"${_mm_f}_available"
done

# ------------------------------------------------------------------------- uninstall ----

if [ "$UNINSTALL" -eq 1 ]; then
	detect_user
	STEP="removing Machman's guest configuration"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would remove every line, file and service carrying $MARKER"
		exit 0
	fi
	for _mm_f in $FEATURES; do
		"${_mm_f}_uninstall"
	done
	# The shared fstab block (virtiofs + sshfs automounts) strips once, here.
	[ -f /etc/fstab ] && strip_block /etc/fstab
	remove_state
	write_report uninstalled
	ok "Machman's guest configuration is gone."
	note "Installed packages and the SSH server stay — remove them yourself if unwanted."
	exit 0
fi

# ------------------------------------------------------------------ feature selection ----

# Menu over the AVAILABLE features. Every row carries its VERB — what selecting it will
# actually do here (set up, verify, adopt-or-report, refresh) — from the feature's own
# probes; each feature also owns its default (ON for core work and anything it manages
# already, OFF for opt-ins). Flags override.
AVAILABLE_FEATURES=""
_mm_menu=""
_mm_marks=""
_mm_i=0
for _mm_f in $FEATURES; do
	# Kernel console is FLAG-ONLY: it edits the boot loader, so the menu never offers
	# it — the plan shows its state, and --kernel-console selects it explicitly below.
	[ "$_mm_f" = kernelconsole ] && continue
	_mm_avail="$(eval "printf '%s' \"\$avail_$_mm_f\"")"
	[ "$_mm_avail" = 1 ] || continue
	AVAILABLE_FEATURES="$AVAILABLE_FEATURES $_mm_f"
	_mm_i=$((_mm_i + 1))
	_mm_menu="$_mm_menu$(printf '%s   %s' "$(feature_title "$_mm_f")" \
		"$("${_mm_f}_menu_note")")
"
	_mm_want="$(eval "printf '%s' \"\$want_$_mm_f\"")"
	_mm_on=0
	if [ -n "$_mm_want" ]; then
		_mm_on="$_mm_want"
	else
		_mm_on="$("${_mm_f}_menu_default")"
	fi
	if [ "$_mm_on" = 1 ]; then
		toggle_mark "$_mm_marks" "$_mm_i"
		_mm_marks="$R_MARKS"
	fi
done
AVAILABLE_FEATURES="${AVAILABLE_FEATURES# }"
_mm_menu="$(printf '%s' "$_mm_menu")"

[ -n "$AVAILABLE_FEATURES" ] || die 3 "nothing this script can set up on this guest." \
	"The report (if writable) says why each feature is unavailable."

say ""
say "${C_BOLD}Machman guest setup${C_RESET} — VM \"$VM_NAME\", script v$SCRIPT_VERSION"
if [ "$HAD_STATE" -eq 1 ]; then
	say "${C_DIM}Configured before by script v${ST_SCRIPT_VERSION:-?}" \
		"— re-running verifies, repairs and reconfigures.${C_RESET}"
fi
say ""
menu_multi "Set up which features?" "$_mm_menu" "$_mm_marks"
_mm_i=0
for _mm_f in $AVAILABLE_FEATURES; do
	_mm_i=$((_mm_i + 1))
	case ",$R_MARKS," in
	*",$_mm_i,"*) SELECTED_FEATURES="$SELECTED_FEATURES $_mm_f" ;;
	esac
done
SELECTED_FEATURES="${SELECTED_FEATURES# }"
# The flag-only feature: an explicit --kernel-console joins the run here.
if [ "${want_kernelconsole:-}" = 1 ]; then
	if [ "$avail_kernelconsole" = 1 ]; then
		SELECTED_FEATURES="$SELECTED_FEATURES kernelconsole"
		SELECTED_FEATURES="${SELECTED_FEATURES# }"
	else
		warn "--kernel-console: $reason_kernelconsole"
	fi
fi
[ -n "$SELECTED_FEATURES" ] || die 3 "nothing selected — nothing to do."

# Dependencies: sshfs work rides the guest -> host link. Selecting the tool or the
# automounts pulls the link in; the automounts also pull the tool.
if feature_selected sshfsauto; then
	feature_selected sshfs || SELECTED_FEATURES="$SELECTED_FEATURES sshfs"
	feature_selected reverse || SELECTED_FEATURES="$SELECTED_FEATURES reverse"
fi
if feature_selected sshfs && ! feature_selected reverse; then
	if [ "$avail_reverse" = 1 ] && [ "${want_reverse:-}" != 0 ]; then
		SELECTED_FEATURES="$SELECTED_FEATURES reverse"
	fi
fi

# The ssh-shaped features need a package manager and a target user.
case " $SELECTED_FEATURES " in
*" ssh "*|*" reverse "*|*" sshfs "*|*" sshfsauto "*)
	detect_pm
	detect_user
	;;
*)
	case "$OS_FAMILY" in
	nixos) : ;;
	*) detect_pm ;;
	esac
	;;
esac

# ------------------------------------------------------------------ decide + preflight ----

for _mm_f in $FEATURES; do
	feature_selected "$_mm_f" && "${_mm_f}_decide"
done

say ""
plan_line "guest" "${OS_ID}${OS_VERSION:+ $OS_VERSION} ($OS_FAMILY), $INIT init${PM_NAME:+, $PM_NAME}"
plan_line "payload" "$PAYLOAD_DIR (over $TRANSPORT)"
for _mm_f in $FEATURES; do
	feature_selected "$_mm_f" && "${_mm_f}_plan"
done
# The flag-only feature's state, always visible even when it is not in the run.
kernelconsole_status_line
# Configured features that were NOT selected: named, so nothing is silently ambiguous.
_mm_left=""
for _mm_f in $FEATURES; do
	[ "$_mm_f" = kernelconsole ] && continue   # it has its own status line above
	feature_selected "$_mm_f" && continue
	_mm_avail="$(eval "printf '%s' \"\$avail_$_mm_f\"")"
	[ "$_mm_avail" = 1 ] || continue
	if "${_mm_f}_is_configured"; then
		_mm_left="$_mm_left$(feature_title "$_mm_f"), "
	fi
done
[ -n "$_mm_left" ] && plan_line "left as is" "${_mm_left%, } (configured)"
_mm_skipped=""
for _mm_f in $FEATURES; do
	_mm_avail="$(eval "printf '%s' \"\$avail_$_mm_f\"")"
	if [ "$_mm_avail" != 1 ]; then
		_mm_reason="$(eval "printf '%s' \"\$reason_$_mm_f\"")"
		[ -n "$_mm_reason" ] \
			&& _mm_skipped="$_mm_skipped$(feature_title "$_mm_f"): $_mm_reason
"
	fi
done
if [ -d "$REPORT_DIR" ] && [ -w "$REPORT_DIR" ]; then
	plan_line "report" "$REPORT_DIR"
else
	plan_line "report" "NOT writable — Machman will not learn any of this"
fi
say ""

if [ "$DRY_RUN" -eq 1 ]; then
	if [ -n "$_mm_skipped" ]; then
		say "Unavailable here:"
		printf '%s' "$_mm_skipped" | while IFS= read -r _mm_line; do
			[ -n "$_mm_line" ] && note "$_mm_line"
		done
	fi
	say "Dry run — nothing was changed."
	exit 0
fi

ask_yes_no "Proceed?" y
[ "$R_YES" = 1 ] || die 3 "cancelled — nothing was changed."
PREFLIGHT_DONE=1
say ""

# ------------------------------------------------------------------------------- act ----

for _mm_f in $FEATURES; do
	feature_selected "$_mm_f" && "${_mm_f}_act"
done

# The state file's truth: selected features re-probe what this run MANAGES (never a
# foreign artifact); unselected features keep their previous record.
_mm_configured=""
for _mm_f in $FEATURES; do
	if ! feature_selected "$_mm_f"; then
		state_was_configured "$_mm_f" && _mm_configured="$_mm_configured $_mm_f"
		continue
	fi
	case "$_mm_f" in
	console)
		[ -n "$CONSOLE_MANAGED" ] && _mm_configured="$_mm_configured console" ;;
	kernelconsole)
		[ -n "$KC_DEVICE_DONE" ] && _mm_configured="$_mm_configured kernelconsole" ;;
	ssh)
		_mm_configured="$_mm_configured ssh" ;;
	reverse)
		[ -n "$REVERSE_PUBKEY" ] && _mm_configured="$_mm_configured reverse" ;;
	sshfs)
		[ "$SSHFS" -eq 1 ] && _mm_configured="$_mm_configured sshfs" ;;
	vfsauto)
		vfsauto_configured && _mm_configured="$_mm_configured vfsauto" ;;
	sshfsauto)
		[ -n "$SSHFSAUTO_DONE" ] && _mm_configured="$_mm_configured sshfsauto" ;;
	esac
done
write_state "${_mm_configured# }"
find_addresses
write_report

# --------------------------------------------------------------------------- summary ----

say ""
if [ -n "$_mm_skipped" ]; then
	say "Unavailable here:"
	printf '%s' "$_mm_skipped" | while IFS= read -r _mm_line; do
		[ -n "$_mm_line" ] && note "$_mm_line"
	done
fi
if [ -n "$FAILED_STEPS" ]; then
	warn "done, with gaps: $FAILED_STEPS"
	note "Machman's Guest Setup inspector shows what is missing."
	MACHMAN_DIED=1   # an explained outcome — the trap stays quiet
	exit 4
fi
ok "done — guest setup is complete."
if feature_selected ssh && [ -n "$IP" ]; then
	say "From your Mac:    ssh $U@$IP"
fi
say "Machman's Guest Setup inspector shows this VM's state."
