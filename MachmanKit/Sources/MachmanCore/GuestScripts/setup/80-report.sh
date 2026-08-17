# === machman-setup: 80-report ===
# The report Machman ingests: flat key=value lines, written whenever the drop-box is
# writable — including on failure, so Machman can say what went wrong instead of just
# "no report yet". v2's keys are kept verbatim (the host's parser whitelists and old
# daemons ignore what they don't know); v3 adds FEATURE_/CONSOLE_/AUTOMOUNT_/ERROR_ lines.

# Set for real by 90-main; defaulted here so the failure trap can report from any phase.
FEATURES="${FEATURES:-}"
SELECTED_FEATURES=""

# The wire vocabulary for feature ids (GuestFeature in MachmanAPI).
wire_id() {
	case "$1" in
	console) echo console ;;
	kernelconsole) echo kernelConsole ;;
	ssh) echo ssh ;;
	reverse) echo reverseSSH ;;
	sshfs) echo sshfs ;;
	vfsauto) echo virtiofsAutomount ;;
	sshfsauto) echo sshfsAutomount ;;
	esac
}

# feature_line <id> → "FEATURE_<wire>=<state> <detail>" (state: unavailable|available|
# configured; detail = the reason when unavailable, a short fact otherwise).
feature_line() {
	_fl_avail="$(eval "printf '%s' \"\$avail_$1\"")"
	_fl_reason="$(eval "printf '%s' \"\$reason_$1\"")"
	if [ "$_fl_avail" != 1 ]; then
		printf 'FEATURE_%s=unavailable %s\n' "$(wire_id "$1")" "$_fl_reason"
		return 0
	fi
	_fl_state=available
	_fl_detail=""
	case "$1" in
	console)
		_fl_cfg=""
		for _fl_dev in $CONSOLE_DEVICES; do
			case "$(console_login_state "$_fl_dev")" in
			active|active-auto|configured)
				if [ "$(console_ownership "$_fl_dev")" = foreign ]; then
					_fl_cfg="$_fl_cfg $_fl_dev (external)"
				else
					_fl_cfg="$_fl_cfg $_fl_dev"
				fi
				;;
			esac
		done
		_fl_cfg="${_fl_cfg# }"
		[ -n "$_fl_cfg" ] && { _fl_state=configured; _fl_detail="$_fl_cfg"; }
		;;
	kernelconsole)
		if [ -n "$KC_DEVICE_DONE" ]; then
			_fl_state=configured; _fl_detail="$KC_DEVICE_DONE"
		elif [ -n "$CMDLINE_CONSOLES" ]; then
			for _fl_dev in $CONSOLE_DEVICES; do
				if has_word "$_fl_dev" "$CMDLINE_CONSOLES"; then
					_fl_state=configured; _fl_detail="$_fl_dev"
				fi
			done
		fi
		;;
	ssh)
		# Re-probe: the act may just have installed or switched the marker's owner.
		ssh_find_installed_user
		if [ -n "$SSH_INSTALLED_USER" ]; then
			_fl_state=configured; _fl_detail="$SSH_INSTALLED_USER"
		fi
		;;
	reverse)
		if reverse_is_configured; then
			_fl_state=configured; _fl_detail="${SSH_INSTALLED_USER:-$U}"
		elif state_was_configured reverse; then
			_fl_state=configured
		fi
		;;
	sshfs)
		[ "$SSHFS" -eq 1 ] && { _fl_state=configured; _fl_detail="${SSHFS_VERSION:-}"; }
		;;
	vfsauto)
		if vfsauto_configured; then
			_fl_state=configured; _fl_detail="$SHARE_ROOT"
		elif vfsauto_foreign; then
			_fl_state=configured; _fl_detail="$SHARE_ROOT (external)"
		fi
		;;
	sshfsauto)
		if [ -n "$SSHFSAUTO_DONE" ]; then
			_fl_state=configured; _fl_detail="$SSHFSAUTO_DONE"
		elif sshfsauto_configured; then
			_fl_state=configured; _fl_detail="${ST_AUTOMOUNT_SSHFS:-}"
		fi
		;;
	esac
	printf 'FEATURE_%s=%s%s\n' "$(wire_id "$1")" "$_fl_state" "${_fl_detail:+ $_fl_detail}"
	return 0
}

# Always written when the drop-box is writable. Rename-into-place, so the host never
# reads a half-file.
write_report() {
	_wr_mode="${1:-}"
	if [ ! -d "$REPORT_DIR" ] || [ ! -w "$REPORT_DIR" ]; then
		return 0
	fi
	_wr_status=ok
	case "$_wr_mode" in
	failed) _wr_status=failed ;;
	uninstalled) _wr_status=ok ;;
	*) [ -n "$FAILED_STEPS" ] && _wr_status=partial ;;
	esac
	{
		printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
		printf 'MARKER=%s\n' "$MARKER"
		printf 'STATUS=%s\n' "$_wr_status"
		[ -n "$FAILED_STEPS" ] && printf 'FAILED_STEPS=%s\n' "$FAILED_STEPS"
		if [ "$_wr_status" = failed ]; then
			printf 'NOTE=%s\n' "${R_LAST_FAILURE:-stopped during: ${STEP:-startup}}"
		elif [ -n "$R_LAST_FAILURE" ]; then
			printf 'NOTE=%s\n' "$R_LAST_FAILURE"
		fi
		printf 'TRANSPORT=%s\n' "$TRANSPORT"
		printf 'OS_ID=%s\n' "$OS_ID"
		printf 'OS_FAMILY=%s\n' "$OS_FAMILY"
		[ -n "$OS_VERSION" ] && printf 'OS_VERSION=%s\n' "$OS_VERSION"
		printf 'INIT=%s\n' "$INIT"
		printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null || true)"
		printf 'IP=%s\n' "$IP"
		printf 'GATEWAY=%s\n' "$GATEWAY"
		if [ "$_wr_mode" != uninstalled ]; then
			for _wr_f in $FEATURES; do
				feature_line "$_wr_f"
			done
			console_report
			kernelconsole_report
			if has_word ssh "$SELECTED_FEATURES"; then
				ssh_report
			fi
			if has_word reverse "$SELECTED_FEATURES"; then
				reverse_report
			fi
			if has_word sshfs "$SELECTED_FEATURES" || [ "$SSHFS" -eq 1 ]; then
				sshfs_report
			fi
			_wr_i=1
			printf '%s\n' "$AUTOMOUNT_LINES" | while IFS= read -r _wr_line; do
				[ -n "$_wr_line" ] || continue
				printf 'AUTOMOUNT_%s=%s\n' "$_wr_i" "$_wr_line" | tr '\t' ' '
				_wr_i=$((_wr_i + 1))
			done
			_wr_i=1
			printf '%s\n' "$ERR_LINES" | while IFS= read -r _wr_line; do
				[ -n "$_wr_line" ] || continue
				printf 'ERROR_%s=%s\n' "$_wr_i" "$_wr_line"
				_wr_i=$((_wr_i + 1))
			done
		fi
		[ "$_wr_mode" = uninstalled ] && printf 'UNINSTALLED=1\n'
		:
	} > "$REPORT_DIR/report.env.tmp"
	mv "$REPORT_DIR/report.env.tmp" "$REPORT_DIR/report.env"
	REPORT_DONE=1
	verbose report "wrote $REPORT_DIR/report.env (status=$_wr_status)"
	return 0
}
