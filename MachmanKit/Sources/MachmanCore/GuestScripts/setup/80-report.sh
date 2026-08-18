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
	*)
		if [ "${REPORT_ONLY:-0}" -eq 1 ]; then
			# A probe run describes the LAST real run's outcome, not its own.
			_wr_status="${ST_LAST_STATUS:-ok}"
		elif [ -n "$FAILED_STEPS" ]; then
			_wr_status=partial
		fi
		;;
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

# ---------------------------------------------------------------- boot-time refresh ----
# A tiny per-init hook re-runs this script with --report-only at boot, so states a run
# could only promise ("configured", "pending reboot") flip to what the guest actually
# does once it reboots. The payload is regenerated at every VM start and gone when the
# VM is off, so the hook no-ops unless Machman is serving the share. FreeBSD gets its
# own rc.d script — NOT an /etc/rc.local line: the sshfs boot mounts own a marker block
# there and both sides strip_block the whole file, so they would clobber each other.

report_hook_install() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	_rh_script="$SHARE_ROOT/GuestSetup/$(basename "$0")"
	case "$INIT" in
	systemd)
		{
			printf '# %s\n' "$MARKER"
			printf '[Unit]\n'
			printf 'Description=Machman guest report refresh\n'
			printf 'ConditionPathExists=%s\n' "$_rh_script"
			printf 'After=local-fs.target network.target\n'
			printf '\n[Service]\nType=oneshot\n'
			printf 'ExecStart=/bin/sh %s --report-only -q\n' "$_rh_script"
			printf '\n[Install]\nWantedBy=multi-user.target\n'
		} > /etc/systemd/system/machman-report.service
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable machman-report.service >/dev/null 2>&1 || true
		;;
	openrc)
		mkdir -p /etc/local.d
		{
			printf '#!/bin/sh\n# %s\n' "$MARKER"
			printf '[ -r "%s" ] || exit 0\n' "$_rh_script"
			printf 'sh "%s" --report-only -q >/dev/null 2>&1 &\n' "$_rh_script"
		} > /etc/local.d/machman-report.start
		chmod 755 /etc/local.d/machman-report.start
		have rc-update && rc-update add local default >/dev/null 2>&1
		;;
	inittab|sysv|runit|openbsd-rc)
		# /etc/local.d is openrc's mechanism — nothing executes it under these inits.
		# They all run /etc/rc.local (sysvinit via the distro's rc.local service, Void's
		# runit stage, OpenBSD's rc), so the hook lands there.
		report_hook_rc_local "$_rh_script"
		;;
	freebsd-rc)
		# REQUIRE: local orders after /etc/rc.d/local, which runs /etc/rc.local — where
		# the sshfs automounts connect — so the share is mounted before the probe. The
		# grace sleep covers the mount settling; the guard makes any miss a silent no-op.
		{
			printf '#!/bin/sh\n'
			printf '# %s — Machman guest report refresh\n' "$MARKER"
			printf '# PROVIDE: machman_report\n'
			printf '# REQUIRE: local\n'
			printf '\n. /etc/rc.subr\n\n'
			printf 'name=machman_report\n'
			printf 'rcvar=machman_report_enable\n'
			printf 'start_cmd="machman_report_start"\n'
			printf 'stop_cmd=":"\n\n'
			printf 'machman_report_start() {\n'
			printf '\t(sleep 5; [ -r "%s" ] && /bin/sh "%s" --report-only -q) &\n' \
				"$_rh_script" "$_rh_script"
			printf '}\n\n'
			printf 'load_rc_config $name\n'
			printf ': ${machman_report_enable:=YES}\n'
			printf 'run_rc_command "$1"\n'
		} > /usr/local/etc/rc.d/machman_report
		chmod 755 /usr/local/etc/rc.d/machman_report
		;;
	launchd)
		{
			printf '<?xml version="1.0" encoding="UTF-8"?>\n'
			printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
			printf ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
			printf '<plist version="1.0"><dict>\n'
			printf '<key>Label</key><string>com.machman.report</string>\n'
			printf '<!-- %s -->\n' "$MARKER"
			printf '<key>ProgramArguments</key><array>\n'
			printf '<string>/bin/sh</string><string>%s</string>\n' "$_rh_script"
			printf '<string>--report-only</string><string>-q</string>\n'
			printf '</array>\n'
			printf '<key>RunAtLoad</key><true/>\n'
			printf '</dict></plist>\n'
		} > /Library/LaunchDaemons/com.machman.report.plist
		chmod 644 /Library/LaunchDaemons/com.machman.report.plist
		launchctl bootstrap system /Library/LaunchDaemons/com.machman.report.plist \
			>/dev/null 2>&1 || true
		;;
	*)
		note "no boot-time report refresh under init '$INIT' — reports update on re-runs only."
		return 0
		;;
	esac
	verbose report "boot refresh hook installed ($INIT)"
	return 0
}

# The shared-file arm: a marker block in /etc/rc.local. The marker carries a "-report"
# suffix so it never collides with the sshfs automounts' block, which strip_blocks the
# PLAIN marker over this same file — and the block must not `exit`: rc.local is shared,
# later lines still have to run. The settle sleep and the -r guard mirror the FreeBSD
# hook: the share this script lives on may be mounted by an earlier rc.local line.
report_hook_rc_local() {
	if [ ! -f /etc/rc.local ]; then
		printf '#!/bin/sh\n' > /etc/rc.local
		chmod 755 /etc/rc.local
	fi
	# Pre-fix runs on sysvinit wrote openrc's file here; it was never executed — retire it.
	rm -f /etc/local.d/machman-report.start 2>/dev/null || true
	( MARKER="$MARKER-report"; strip_block /etc/rc.local )
	{
		printf '# BEGIN %s-report\n' "$MARKER"
		printf '(sleep 5; [ -r "%s" ] && /bin/sh "%s" --report-only -q) >/dev/null 2>&1 &\n' \
			"$1" "$1"
		printf '# END %s-report\n' "$MARKER"
	} >> /etc/rc.local
	return 0
}

report_hook_uninstall() {
	rm -f /etc/systemd/system/machman-report.service \
		/etc/systemd/system/multi-user.target.wants/machman-report.service \
		/etc/local.d/machman-report.start \
		/usr/local/etc/rc.d/machman_report 2>/dev/null || true
	if [ -f /etc/rc.local ]; then
		( MARKER="$MARKER-report"; strip_block /etc/rc.local )
	fi
	have systemctl && systemctl daemon-reload >/dev/null 2>&1
	if [ -f /Library/LaunchDaemons/com.machman.report.plist ]; then
		launchctl bootout system/com.machman.report >/dev/null 2>&1 || true
		rm -f /Library/LaunchDaemons/com.machman.report.plist
	fi
	return 0
}
