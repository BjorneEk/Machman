# === machman-setup: 80-report ===
# The report Machman ingests: flat key=value lines, written whenever the drop-box is
# writable — including on failure, so Machman can say what went wrong instead of just
# "no report yet". v2's keys are kept verbatim (the host's parser whitelists and old
# daemons ignore what they don't know); v3 adds FEATURE_/CONSOLE_/AUTOMOUNT_/ERROR_ lines,
# v4, v6 and v7 no keys, v5 NOTE_ lines, v8 SCRIPT_CKSUM (the running script's cksum). An AUTOMOUNT_ row is TAB-separated only when its
# mount name has a space, and NOTE_ lines carry what the run noted without failing (an
# older daemon drops them).

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
			_fl_state=configured; _fl_detail="$(tab_list_join "$SSHFSAUTO_DONE")"
		elif sshfsauto_configured; then
			_fl_state=configured; _fl_detail="$(tab_list_join "$ST_AUTOMOUNT_SSHFS")"
		fi
		;;
	esac
	printf 'FEATURE_%s=%s%s\n' "$(wire_id "$1")" "$_fl_state" "${_fl_detail:+ $_fl_detail}"
	return 0
}

# The AUTOMOUNT_ lines of the automounts this run leaves as they are (a --report-only run:
# all of them): their entries stay in place, so the report keeps listing them, each where
# its entry mounts it — the share's own sshfs mount at the share root (sshfsauto_entry).
automount_lines_kept() {
	if ! feature_selected vfsauto && { vfsauto_configured || vfsauto_foreign; }; then
		AUTOMOUNT_LINES="${AUTOMOUNT_LINES:+$AUTOMOUNT_LINES
}virtiofs	$SHARE_TAG	$SHARE_ROOT"
	fi
	feature_selected sshfsauto && return 0
	# Mount names are host text, TAB-separated: never split at a space nor globbed.
	_alk_ifs="$IFS"
	IFS="$(printf '\t')"
	set -f
	# shellcheck disable=SC2086
	set -- $ST_AUTOMOUNT_SSHFS
	set +f
	IFS="$_alk_ifs"
	for _alk_n in "$@"; do
		if [ "$_alk_n" = "@share" ]; then
			_alk_where="$SHARE_ROOT"
		else
			_alk_where="${ST_MOUNTPOINT:-$MOUNT_ROOT}/$_alk_n"
		fi
		AUTOMOUNT_LINES="${AUTOMOUNT_LINES:+$AUTOMOUNT_LINES
}sshfs	$_alk_n	$_alk_where"
	done
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
	# Composed in a root-only temp file: the brace group must run in THIS shell (the
	# probes it calls set globals), so it cannot feed write_file through a pipe.
	_wr_tmp="$(mktemp)" || return 0
	{
		printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
		_wr_cksum="$(script_cksum)"
		[ -n "$_wr_cksum" ] && printf 'SCRIPT_CKSUM=%s\n' "$_wr_cksum"
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
			# kind target path, space-separated as every daemon reads them — or, when the
			# target (a mount name) has a space, TAB-separated so it arrives whole.
			_wr_i=1
			_wr_tab="$(printf '\t')"
			printf '%s\n' "$AUTOMOUNT_LINES" \
				| while IFS="$_wr_tab" read -r _wr_kind _wr_target _wr_path; do
				[ -n "$_wr_kind" ] || continue
				case "$_wr_target" in
				*" "*) _wr_sep="$_wr_tab" ;;
				*) _wr_sep=" " ;;
				esac
				printf 'AUTOMOUNT_%s=%s%s%s%s%s\n' "$_wr_i" \
					"$_wr_kind" "$_wr_sep" "$_wr_target" "$_wr_sep" "$_wr_path"
				_wr_i=$((_wr_i + 1))
			done
			_wr_i=1
			printf '%s\n' "$ERR_LINES" | while IFS= read -r _wr_line; do
				[ -n "$_wr_line" ] || continue
				printf 'ERROR_%s=%s\n' "$_wr_i" "$_wr_line"
				_wr_i=$((_wr_i + 1))
			done
			_wr_i=1
			printf '%s\n' "$NOTE_LINES" | while IFS= read -r _wr_line; do
				[ -n "$_wr_line" ] || continue
				printf 'NOTE_%s=%s\n' "$_wr_i" "$_wr_line"
				_wr_i=$((_wr_i + 1))
			done
		fi
		[ "$_wr_mode" = uninstalled ] && printf 'UNINSTALLED=1\n'
		:
	} > "$_wr_tmp"
	# Whoever mounted the share (the sshfs bootstrap, a macOS guest's user) can write the
	# drop-box: the report goes in by write_file, never through a planted name.
	if ! write_file "$REPORT_DIR/report.env" < "$_wr_tmp"; then
		rm -f "$_wr_tmp"
		warn "could not write Machman's report: $R_ERROR"
		return 0
	fi
	rm -f "$_wr_tmp"
	REPORT_DONE=1
	verbose report "wrote $REPORT_DIR/report.env (status=$_wr_status)"
	return 0
}

# ---------------------------------------------------------------- boot-time refresh ----
# A tiny per-init hook re-runs this script with --report-only at boot, so states a run
# could only promise ("configured", "pending reboot") flip to what the guest actually
# does once it reboots. It runs the guest's OWN copy of the script, kept beside the state
# (report_copy_install), never the share's: an installed guest is not served the payload,
# and macOS mounts the share elsewhere. FreeBSD gets its own rc.d script — NOT an
# /etc/rc.local line: the sshfs boot mounts own a marker block there and both sides
# strip_block the whole file, so they would clobber each other.

REPORT_COPY=""             # the boot-time copy, once report_copy_install wrote it
RC_LOCAL=/etc/rc.local     # the shared boot file the rc.local hooks keep their blocks in
OPENRC_LOCAL_D=/etc/local.d   # the scripts openrc's local service runs at boot

# --at-boot: the hooks start it early (in the background, so boot never waits on it).
# It waits until the share's drop-box is writable and the guest has a default route —
# the report and the sshfs automounts need both — or until BOOT_WAIT_SECONDS pass, then
# reports what is true: a missing route is the truth then, and a drop-box that never
# appeared means no report.
boot_wait() {
	_bw_waited=0
	while :; do
		find_addresses
		if [ -d "$REPORT_DIR" ] && [ -w "$REPORT_DIR" ] && [ -n "$GATEWAY" ]; then
			return 0
		fi
		[ "$_bw_waited" -lt "$BOOT_WAIT_SECONDS" ] || return 0
		sleep "$BOOT_WAIT_POLL"
		_bw_waited=$((_bw_waited + (BOOT_WAIT_POLL > 0 ? BOOT_WAIT_POLL : 1)))
	done
}

report_hook_install() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	if [ "$OS_FAMILY" = nixos ]; then
		# /etc/systemd/system is generated from configuration.nix (read-only).
		report_note report-refresh \
			"no boot-time report refresh on NixOS — the report updates when this script runs"
		return 0
	fi
	case "$INIT" in
	systemd|openrc|inittab|sysv|runit|openbsd-rc|netbsd-rc|freebsd-rc|launchd) ;;
	*)
		report_note report-refresh \
			"no boot-time report refresh under init '$INIT' — reports update on re-runs only"
		return 0
		;;
	esac
	if ! report_copy_install; then
		report_note report-refresh "no boot-time report refresh: $R_ERROR"
		return 0
	fi
	_rh_copy="$(sh_quote "$REPORT_COPY")"
	case "$INIT" in
	systemd)
		report_hook_file /etc/systemd/system/machman-report.service 644 "$(
			printf '# %s\n' "$MARKER"
			printf '[Unit]\n'
			printf 'Description=Machman guest report refresh\n'
			printf 'ConditionPathExists=%s\n' "$REPORT_COPY"
			# Ordered after the network is up; simple, not oneshot: a oneshot would hold
			# multi-user.target for as long as the copy waits.
			printf 'Wants=network-online.target\n'
			printf 'After=local-fs.target remote-fs.target network-online.target\n'
			printf '\n[Service]\nType=simple\n'
			printf 'ExecStart=/bin/sh %s --at-boot -q\n' "$REPORT_COPY"
			printf '\n[Install]\nWantedBy=multi-user.target'
		)" || return 0
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable machman-report.service >/dev/null 2>&1 || true
		;;
	openrc)
		mkdir -p /etc/local.d
		report_hook_file /etc/local.d/machman-report.start 755 "$(
			printf '#!/bin/sh\n# %s\n' "$MARKER"
			printf '[ -r %s ] || exit 0\n' "$_rh_copy"
			printf '/bin/sh %s --at-boot -q >/dev/null 2>&1 &' "$_rh_copy"
		)" || return 0
		openrc_local_enable || true
		;;
	inittab|sysv|runit|openbsd-rc|netbsd-rc)
		# /etc/local.d is openrc's mechanism — nothing executes it under these inits.
		# They all run /etc/rc.local (sysvinit via the distro's rc.local service, Void's
		# runit stage, OpenBSD's rc, NetBSD's rc.d/local), so the hook lands there.
		report_hook_rc_local "$_rh_copy"
		;;
	freebsd-rc)
		# REQUIRE: local orders after /etc/rc.d/local, which runs /etc/rc.local — where
		# the sshfs automounts connect; --at-boot waits for them to settle.
		mkdir -p /usr/local/etc/rc.d
		report_hook_file /usr/local/etc/rc.d/machman_report 755 "$(
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
			printf '\t([ -r %s ] && /bin/sh %s --at-boot -q) &\n' "$_rh_copy" "$_rh_copy"
			printf '}\n\n'
			printf 'load_rc_config $name\n'
			printf ': ${machman_report_enable:=YES}\n'
			printf 'run_rc_command "$1"'
		)" || return 0
		;;
	launchd)
		# Loaded at the next boot, never now: it would race this run's own report. One an
		# older run loaded (pointing at the share) goes now.
		launchctl bootout system/com.machman.report >/dev/null 2>&1 || true
		report_hook_file "$LAUNCHD_DIR/com.machman.report.plist" 644 "$(
			printf '<?xml version="1.0" encoding="UTF-8"?>\n'
			printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
			printf ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
			printf '<plist version="1.0"><dict>\n'
			printf '<key>Label</key><string>com.machman.report</string>\n'
			printf '<!-- %s -->\n' "$MARKER"
			printf '<key>ProgramArguments</key><array>\n'
			printf '<string>/bin/sh</string><string>%s</string>\n' "$REPORT_COPY"
			printf '<string>--at-boot</string><string>-q</string>\n'
			printf '</array>\n'
			printf '<key>RunAtLoad</key><true/>\n'
			printf '</dict></plist>'
		)" || return 0
		;;
	esac
	verbose report "boot refresh hook installed ($INIT)"
	return 0
}

# report_hook_file <path> <mode> <content> — a hook file written whole (never through a
# link); a failure is the report's note, and the hook is not installed. 1 then.
report_hook_file() {
	if ! write_file -m "$2" "$1" <<EOF
$3
EOF
	then
		report_note report-refresh "no boot-time report refresh: $R_ERROR"
		return 1
	fi
	return 0
}

# The boot-time copy (decision 11): this script, its machman.env and the files it reads,
# root-only beside the state, so the hook never needs the share's payload. Its machman.env
# adds BOOT_REPORT_DIR — the share's drop-box as this run resolved it — which also locks
# the copy to --report-only. A mounts.list the payload no longer ships goes. 1 with
# R_ERROR when any of it cannot be written.
report_copy_install() {
	REPORT_COPY="$STATE_DIR/report.sh"
	R_ERROR=""
	if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
		R_ERROR="could not create $STATE_DIR"
		return 1
	fi
	if [ ! -r "$PAYLOAD_DIR/${0##*/}" ]; then
		R_ERROR="cannot read $PAYLOAD_DIR/${0##*/} to copy it"
		return 1
	fi
	write_file -m 700 "$REPORT_COPY" < "$PAYLOAD_DIR/${0##*/}" || return 1
	write_file -m 600 "$STATE_DIR/machman.env" <<EOF || return 1
$(cat "$PAYLOAD_DIR/machman.env")
BOOT_REPORT_DIR=$(sh_quote "$REPORT_DIR")
EOF
	if [ -r "$PAYLOAD_DIR/host_key.pub" ]; then
		write_file -m 644 "$STATE_DIR/host_key.pub" < "$PAYLOAD_DIR/host_key.pub" || return 1
	fi
	if [ -r "$MOUNTS_LIST" ]; then
		write_file -m 644 "$STATE_DIR/mounts.list" < "$MOUNTS_LIST" || return 1
	else
		rm -f "$STATE_DIR/mounts.list"
	fi
	return 0
}

# The shared-file arm: a marker block in /etc/rc.local. The marker carries a "-report"
# suffix so it never collides with the sshfs automounts' block, which strip_blocks the
# PLAIN marker over this same file — and the block must not `exit`: rc.local is shared,
# later lines still have to run. It goes to the background like the FreeBSD hook, whose
# --at-boot waits for the share an earlier rc.local line may still be mounting.
# report_hook_rc_local <the copy's path, sh-quoted>
report_hook_rc_local() {
	# Pre-fix runs on sysvinit wrote openrc's file here; it was never executed — retire it.
	rm -f /etc/local.d/machman-report.start 2>/dev/null || true
	if ! rc_local_ready report-refresh; then
		report_note report-refresh \
			"/etc/rc.local is not executable, so the boot-time report refresh will not run"
		return 0
	fi
	if ! rc_local_put "$MARKER-report" "$(printf \
		'([ -r %s ] && /bin/sh %s --at-boot -q) >/dev/null 2>&1 &' \
		"$1" "$1")"; then
		report_note report-refresh "no boot-time report refresh: $R_ERROR"
		return 0
	fi
	return 0
}

# rc_local_put <marker> <body> — that marker's block in /etc/rc.local, ahead of its final
# exit. A missing rc.local is created "#!/bin/sh", 0755 (the ledger says a run made it); an
# existing one keeps its mode.
rc_local_put() {
	if [ ! -e "$RC_LOCAL" ] && [ ! -L "$RC_LOCAL" ]; then
		# A here-doc, not a pipe: write_file must run in this shell to hand back R_ERROR.
		_rlp_shebang='#!/bin/sh'
		write_file -m 755 "$RC_LOCAL" <<EOF || return 1
$_rlp_shebang
EOF
		ledger_note rc-local created
	fi
	put_block "$RC_LOCAL" "$1" "$2"
}

# Will the init run /etc/rc.local? Linux inits run it only while it is executable: the
# exec bit is the guest's own on/off switch (Debian's template says so), so a file the
# guest switched off stays off, and nothing is added to it. One that carries a Machman
# block was switched off by an older Machman, which dropped the bit on every edit: that
# one goes back on, and the report says so. The BSDs feed rc.local to sh whatever its
# mode. rc_local_ready <step label>
rc_local_ready() {
	linux_guest || return 0
	# Missing (created executable) or a link (refused by name when written): not this.
	[ -e "$RC_LOCAL" ] && [ ! -L "$RC_LOCAL" ] || return 0
	[ -x "$RC_LOCAL" ] && return 0
	# Any VM's block counts: a cloned disk carries its source VM's marker.
	grep -q '^# BEGIN machman-' "$RC_LOCAL" 2>/dev/null || return 1
	chmod +x "$RC_LOCAL" || return 1
	ledger_note rc-local exec
	report_note "$1" \
		"/etc/rc.local was not executable — re-enabled (Machman's boot hook lives there)"
	return 0
}

# openrc runs /etc/local.d/*.start only while its local service is in the default
# runlevel: enabled for a boot hook where it is not, recorded (openrc-local), so the
# uninstall takes back only what a run added. 1 when it could not be enabled.
openrc_local_enable() {
	have rc-update || return 1
	[ -z "$(rc-update show default 2>/dev/null | awk '$1 == "local"')" ] || return 0
	run "enabling the local boot scripts" rc-update add local default || return 1
	[ "$DRY_RUN" -eq 1 ] || ledger_note openrc-local
	return 0
}

# The uninstall's last word on the local service, once Machman's scripts are out of
# /etc/local.d: disabled when a run enabled it and no other boot script needs it, else
# kept and named.
openrc_local_revert() {
	ledger_has openrc-local && have rc-update || return 0
	for _olr_f in "$OPENRC_LOCAL_D"/*.start; do
		[ -e "$_olr_f" ] || continue
		_olr_kept="the local service stays in the default runlevel (other boot scripts use it)"
		note "$_olr_kept — 'rc-update del local default' reverts it."
		return 0
	done
	run "disabling the local boot scripts" rc-update del local default || true
	return 0
}

# The uninstall's last word on /etc/rc.local, once every Machman block is out of it: a file
# a run created goes while it holds nothing but its first line, and an exec bit a run turned
# on goes off; what the guest keeps there stays, named.
rc_local_revert() {
	[ -f "$RC_LOCAL" ] && [ ! -L "$RC_LOCAL" ] || return 0
	if ledger_has rc-local created; then
		if [ "$(grep -v '^[[:space:]]*$' "$RC_LOCAL")" = '#!/bin/sh' ]; then
			rm -f "$RC_LOCAL" && ok "removed /etc/rc.local (setup created it)"
		else
			note "/etc/rc.local stays — setup created it, and it holds other lines now."
		fi
	elif ledger_has rc-local exec && [ -x "$RC_LOCAL" ]; then
		chmod -x "$RC_LOCAL" && note "/etc/rc.local is not executable again, as before setup."
	fi
	return 0
}

report_hook_uninstall() {
	rm -f /etc/systemd/system/machman-report.service \
		/etc/systemd/system/multi-user.target.wants/machman-report.service \
		/etc/local.d/machman-report.start \
		/usr/local/etc/rc.d/machman_report 2>/dev/null || true
	# The boot-time copy beside the state (remove_state then takes the emptied dir).
	rm -f "$STATE_DIR/report.sh" "$STATE_DIR/machman.env" "$STATE_DIR/host_key.pub" \
		"$STATE_DIR/mounts.list" 2>/dev/null || true
	strip_block "$RC_LOCAL" "$MARKER-report" || uninstall_kept
	# A systemctl without systemd as PID 1 (sysvinit with systemd installed) fails: nothing
	# to reload then, and no reason to abort the uninstall.
	if have systemctl; then
		systemctl daemon-reload >/dev/null 2>&1 || true
	fi
	if [ -f "$LAUNCHD_DIR/com.machman.report.plist" ]; then
		launchctl bootout system/com.machman.report >/dev/null 2>&1 || true
		rm -f "$LAUNCHD_DIR/com.machman.report.plist"
	fi
	return 0
}
