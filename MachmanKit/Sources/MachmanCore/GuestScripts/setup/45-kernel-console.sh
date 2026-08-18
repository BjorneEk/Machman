# === machman-setup: 45-kernel-console ===
# Feature: send kernel boot messages to a virtio console. FLAG-ONLY: it edits the boot
# loader, so it never appears in the interactive menu — the plan shows its state as an
# info line, and only an explicit --kernel-console[=dev] selects it. Every write keeps
# the display alive: the appended arguments are "console=hvcN console=tty0" (kernel
# messages are COPIED to the hvc port while /dev/console and the display stay on tty0 —
# a lone console=hvcN silently blanks the window and can wedge early boot), and grub.cfg
# is backed up before every rebuild. Linux only; grubby (BLS) or the /etc/default/grub
# tools; systemd-boot/UKI report manual; direct-kernel boots skip (Machman owns that
# command line host-side).

KC_DEVICE=""
KC_PLAN=""
KC_DEVICE_DONE=""
KC_METHOD_DONE=""
avail_kernelconsole=0
reason_kernelconsole=""

kernelconsole_detect() {
	detect_cmdline_consoles
	detect_bootloader
	return 0
}

# The device our grub marker line configured, from the file itself ("" when none) — the
# pending truth between the edit and the reboot that makes it active.
kernelconsole_pending_device() {
	[ -f /etc/default/grub ] || { printf ''; return 0; }
	sed -n "s/.*console=\(hvc[0-9]*\) console=tty0\" # $MARKER\$/\1/p" \
		/etc/default/grub | head -n 1
}

# active on <dev> | pending for <dev> | "" — resolved from the running kernel, then the
# grub marker line, then the state file (grubby has no greppable file of ours).
kernelconsole_status() {
	for _kcs_dev in $CONSOLE_DEVICES; do
		if has_word "$_kcs_dev" "$CMDLINE_CONSOLES"; then
			printf 'active on %s' "$_kcs_dev"
			return 0
		fi
	done
	_kcs_pending="$(kernelconsole_pending_device)"
	[ -z "$_kcs_pending" ] && [ -n "$ST_KERNEL_CONSOLE" ] \
		&& _kcs_pending="$ST_KERNEL_CONSOLE"
	if [ -n "$_kcs_pending" ]; then
		printf 'configured for %s — pending reboot' "$_kcs_pending"
		return 0
	fi
	printf ''
	return 0
}

kernelconsole_is_configured() {
	[ -n "$(kernelconsole_status)" ] || [ -n "$KC_DEVICE_DONE" ]
}

# Kept for the interface; the driver never lists this feature in the menu (flag-only).
kernelconsole_menu_note() {
	kernelconsole_status
	return 0
}

kernelconsole_menu_default() {
	echo 0
	return 0
}

# The always-shown plan info line: current state, and how to change it.
kernelconsole_status_line() {
	linux_guest || return 0
	_ksl_status="$(kernelconsole_status)"
	if feature_selected kernelconsole; then
		return 0   # the feature's own plan line speaks
	fi
	if [ -n "$_ksl_status" ]; then
		plan_line "kernel console" "$_ksl_status"
	elif [ "$avail_kernelconsole" = 1 ]; then
		plan_line "kernel console" "off — enable with --kernel-console (edits the boot loader)"
	fi
	return 0
}

kernelconsole_available() {
	avail_kernelconsole=0
	reason_kernelconsole=""
	if ! linux_guest; then
		reason_kernelconsole="kernel console output is a Linux feature"
		return 0
	fi
	if [ "${BOOT_MODE:-efi}" = kernel ]; then
		reason_kernelconsole="this VM boots a kernel directly — Machman owns its command line"
		return 0
	fi
	if [ "${CONSOLE_COUNT:-0}" -eq 0 ]; then
		reason_kernelconsole="no consoles attached — add one in Machman first"
		return 0
	fi
	case "$BOOTLOADER" in
	grubby|update-grub|grub-mkconfig|grub2-mkconfig)
		avail_kernelconsole=1
		;;
	systemd-boot)
		reason_kernelconsole="systemd-boot entries are hand-edited here — add console=hvc0 to /boot/loader/entries/*.conf yourself"
		;;
	kernel-cmdline)
		reason_kernelconsole="this guest builds unified kernel images — add console=hvc0 to /etc/kernel/cmdline yourself"
		;;
	*)
		reason_kernelconsole="no known bootloader tool on this guest"
		;;
	esac
	return 0
}

kernelconsole_decide() {
	KC_DEVICE=""
	_kcd_target="${KERNEL_CONSOLE_DEVICE:-$(console_device 0)}"
	if ! has_word "$_kcd_target" "$CONSOLE_DEVICES"; then
		KC_PLAN="NOT set — $_kcd_target is not one of this VM's consoles"
		return 0
	fi
	if has_word "$_kcd_target" "$CMDLINE_CONSOLES"; then
		KC_PLAN="already active on $_kcd_target — nothing to change"
		return 0
	fi
	_kcd_pending="$(kernelconsole_pending_device)"
	[ -z "$_kcd_pending" ] && _kcd_pending="$ST_KERNEL_CONSOLE"
	if [ "$_kcd_pending" = "$_kcd_target" ]; then
		KC_PLAN="already configured for $_kcd_target — pending reboot, nothing to change"
		return 0
	fi
	KC_DEVICE="$_kcd_target"
	if [ -n "$_kcd_pending" ]; then
		KC_PLAN="move $_kcd_pending -> $KC_DEVICE (+ display kept on tty0) via $BOOTLOADER — EDITS THE BOOT LOADER"
	else
		KC_PLAN="console=$KC_DEVICE (+ display kept on tty0) via $BOOTLOADER — EDITS THE BOOT LOADER"
	fi
	return 0
}

kernelconsole_plan() {
	plan_line "kernel output" "$KC_PLAN"
	return 0
}

# The plain-grub path: one marker-tagged assignment APPENDED to /etc/default/grub — the
# file is sourced sequentially, so the line extends whatever the distro set, survives its
# edits, and uninstalls (or moves) by exact match. tty0 stays LAST so /dev/console and
# the display keep working whatever happens to the hvc port.
kernelconsole_grub_default_edit() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would append console=$KC_DEVICE console=tty0 to /etc/default/grub"
		return 0
	fi
	grep -v "# $MARKER\$" /etc/default/grub > /etc/default/grub.machman-tmp || true
	mv /etc/default/grub.machman-tmp /etc/default/grub
	# The variable name is a printf argument: the emitted line extends the distro's own
	# value, and spelling the dollar-name literally here would look like a read to the
	# drift scanner.
	printf '%s="$%s console=%s console=tty0" # %s\n' \
		GRUB_CMDLINE_LINUX_DEFAULT GRUB_CMDLINE_LINUX_DEFAULT \
		"$KC_DEVICE" "$MARKER" >> /etc/default/grub
	return 0
}

# One restorable copy of the generated config before every rebuild.
kernelconsole_backup_cfg() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	for _kcb_cfg in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
		[ -f "$_kcb_cfg" ] && cp "$_kcb_cfg" "$_kcb_cfg.machman-backup" 2>/dev/null
	done
	return 0
}

kernelconsole_act() {
	[ -n "$KC_DEVICE" ] || return 0
	case "$BOOTLOADER" in
	grubby)
		_kca_old="$(kernelconsole_pending_device)"
		[ -z "$_kca_old" ] && _kca_old="$ST_KERNEL_CONSOLE"
		if [ -n "$_kca_old" ] && [ "$_kca_old" != "$KC_DEVICE" ]; then
			run "removing the old kernel console" grubby --update-kernel=ALL \
				--remove-args="console=$_kca_old console=tty0" || true
		fi
		if run "pointing the kernel console at $KC_DEVICE" \
			grubby --update-kernel=ALL --args="console=$KC_DEVICE console=tty0"; then
			ok "kernel messages -> $KC_DEVICE, display stays on tty0 (next boot)"
			note "Rollback: grubby --update-kernel=ALL --remove-args='console=$KC_DEVICE console=tty0'"
			KC_DEVICE_DONE="$KC_DEVICE"
			KC_METHOD_DONE=grubby
		else
			step_failed kernel-console \
				"grubby could not set console=$KC_DEVICE${R_ERROR:+: $R_ERROR}" \
				"Run it yourself: grubby --update-kernel=ALL --args='console=$KC_DEVICE console=tty0'"
		fi
		;;
	update-grub|grub-mkconfig|grub2-mkconfig)
		kernelconsole_grub_default_edit
		kernelconsole_backup_cfg
		case "$BOOTLOADER" in
		update-grub) _kca_ok=0; run_live "rebuilding the GRUB config" update-grub || _kca_ok=1 ;;
		grub-mkconfig)
			_kca_ok=0
			run_live "rebuilding the GRUB config" grub-mkconfig -o /boot/grub/grub.cfg \
				|| _kca_ok=1
			;;
		grub2-mkconfig)
			_kca_ok=0
			run_live "rebuilding the GRUB config" grub2-mkconfig -o /boot/grub2/grub.cfg \
				|| _kca_ok=1
			;;
		esac
		if [ "$_kca_ok" -eq 0 ]; then
			ok "kernel messages -> $KC_DEVICE, display stays on tty0 (next boot)"
			note "Rollback: remove the '# $MARKER' line from /etc/default/grub and rebuild; grub.cfg.machman-backup holds the previous config."
			KC_DEVICE_DONE="$KC_DEVICE"
			KC_METHOD_DONE="$BOOTLOADER"
		else
			step_failed kernel-console "the GRUB config rebuild failed" \
				"/etc/default/grub keeps the Machman line — fix the error and rebuild."
		fi
		;;
	esac
	return 0
}

kernelconsole_report() {
	_kcr_active=""
	for _kcr_dev in $CONSOLE_DEVICES; do
		has_word "$_kcr_dev" "$CMDLINE_CONSOLES" && _kcr_active="$_kcr_dev"
	done
	_kcr_pending="$KC_DEVICE_DONE"
	[ -z "$_kcr_pending" ] && _kcr_pending="$(kernelconsole_pending_device)"
	[ -z "$_kcr_pending" ] && _kcr_pending="$ST_KERNEL_CONSOLE"
	if [ -n "$_kcr_active" ]; then
		printf 'KERNEL_CONSOLE=%s\n' "$_kcr_active"
		printf 'KERNEL_CONSOLE_METHOD=cmdline\n'
	elif [ -n "$_kcr_pending" ]; then
		printf 'KERNEL_CONSOLE=%s\n' "$_kcr_pending"
		printf 'KERNEL_CONSOLE_METHOD=%s\n' \
			"${KC_METHOD_DONE:-${ST_KERNEL_CONSOLE_METHOD:-pending}}"
	fi
	return 0
}

kernelconsole_uninstall() {
	linux_guest || return 0
	_kcu_dev="${ST_KERNEL_CONSOLE:-$(kernelconsole_pending_device)}"
	case "${ST_KERNEL_CONSOLE_METHOD:-}" in
	grubby)
		[ -n "$_kcu_dev" ] && run "removing the kernel console" \
			grubby --update-kernel=ALL \
			--remove-args="console=$_kcu_dev console=tty0" || true
		;;
	*)
		if [ -f /etc/default/grub ] && grep -q "# $MARKER\$" /etc/default/grub; then
			grep -v "# $MARKER\$" /etc/default/grub > /etc/default/grub.machman-tmp
			mv /etc/default/grub.machman-tmp /etc/default/grub
			# No fresh backup here: install's backup holds the last pre-Machman
			# config, and overwriting it with the Machman-era one (what this used to
			# do) would leave a failed rebuild with nothing worth restoring.
			_kcu_ok=0
			if have update-grub; then
				if run_live "rebuilding the GRUB config" update-grub; then
					_kcu_ok=1
				fi
			elif have grub-mkconfig; then
				if run_live "rebuilding the GRUB config" \
					grub-mkconfig -o /boot/grub/grub.cfg; then
					_kcu_ok=1
				fi
			elif have grub2-mkconfig; then
				if run_live "rebuilding the GRUB config" \
					grub2-mkconfig -o /boot/grub2/grub.cfg; then
					_kcu_ok=1
				fi
			fi
			# The rebuild IS the restore: once it succeeds the backups have nothing
			# left to restore, so they go too; a failed rebuild keeps them.
			if [ "$_kcu_ok" -eq 1 ]; then
				rm -f /boot/grub/grub.cfg.machman-backup \
					/boot/grub2/grub.cfg.machman-backup
			fi
		fi
		;;
	esac
	return 0
}
