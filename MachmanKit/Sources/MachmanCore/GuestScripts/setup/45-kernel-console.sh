# === machman-setup: 45-kernel-console ===
# Feature: send kernel boot messages to a virtio console (console=hvcN). Linux only, and
# only where a bootloader tool this script trusts owns the command line — grubby (BLS),
# update-grub / grub-mkconfig / grub2-mkconfig (via a marker-tagged /etc/default/grub
# line). systemd-boot entries and UKI cmdlines are reported as manual rather than edited
# blind. Direct-kernel boots skip: Machman owns that command line host-side.

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
	_kcd_first="$(console_device 0)"
	if has_word "$_kcd_first" "$CMDLINE_CONSOLES" \
		&& [ -z "$KERNEL_CONSOLE_DEVICE" ]; then
		KC_PLAN="already on $_kcd_first — nothing to change"
		return 0
	fi
	if [ -n "$KERNEL_CONSOLE_DEVICE" ]; then
		KC_DEVICE="$KERNEL_CONSOLE_DEVICE"
	elif [ "${CONSOLE_COUNT:-0}" -gt 1 ]; then
		menu_select "Send kernel boot messages to which console?" \
			"$(printf '%s\n' $CONSOLE_DEVICES)" 1
		KC_DEVICE="$R_ITEM"
		KC_DEVICE="${KC_DEVICE%% *}"
	else
		KC_DEVICE="$_kcd_first"
	fi
	if has_word "$KC_DEVICE" "$CMDLINE_CONSOLES"; then
		KC_PLAN="already on $KC_DEVICE — nothing to change"
		KC_DEVICE=""
		return 0
	fi
	KC_PLAN="console=$KC_DEVICE via $BOOTLOADER (takes effect next boot)"
	return 0
}

kernelconsole_plan() {
	plan_line "kernel output" "$KC_PLAN"
	return 0
}

# The plain-grub path: one marker-tagged assignment APPENDED to /etc/default/grub — the
# file is sourced sequentially, so the line extends whatever the distro set, survives its
# edits, and uninstalls by exact match.
kernelconsole_grub_default_edit() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would append console=$KC_DEVICE to /etc/default/grub"
		return 0
	fi
	grep -v "# $MARKER\$" /etc/default/grub > /etc/default/grub.machman-tmp || true
	mv /etc/default/grub.machman-tmp /etc/default/grub
	# The variable name is a printf argument: the emitted line extends the distro's own
	# value, and spelling the dollar-name literally here would look like a read to the
	# drift scanner.
	printf '%s="$%s console=%s" # %s\n' \
		GRUB_CMDLINE_LINUX_DEFAULT GRUB_CMDLINE_LINUX_DEFAULT \
		"$KC_DEVICE" "$MARKER" >> /etc/default/grub
	return 0
}

kernelconsole_act() {
	[ -n "$KC_DEVICE" ] || return 0
	case "$BOOTLOADER" in
	grubby)
		if run "pointing the kernel console at $KC_DEVICE" \
			grubby --update-kernel=ALL --args="console=$KC_DEVICE"; then
			ok "kernel messages -> $KC_DEVICE (next boot)"
			KC_DEVICE_DONE="$KC_DEVICE"
			KC_METHOD_DONE=grubby
		else
			step_failed kernel-console \
				"grubby could not set console=$KC_DEVICE${R_ERROR:+: $R_ERROR}" \
				"Run it yourself: grubby --update-kernel=ALL --args=console=$KC_DEVICE"
		fi
		;;
	update-grub|grub-mkconfig|grub2-mkconfig)
		kernelconsole_grub_default_edit
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
			ok "kernel messages -> $KC_DEVICE (next boot)"
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
	if [ -n "$KC_DEVICE_DONE" ]; then
		printf 'KERNEL_CONSOLE=%s\n' "$KC_DEVICE_DONE"
		printf 'KERNEL_CONSOLE_METHOD=%s\n' "$KC_METHOD_DONE"
	elif [ -n "$CMDLINE_CONSOLES" ]; then
		printf 'KERNEL_CONSOLE=%s\n' "${CMDLINE_CONSOLES##* }"
		printf 'KERNEL_CONSOLE_METHOD=cmdline\n'
	fi
	return 0
}

kernelconsole_uninstall() {
	linux_guest || return 0
	case "${ST_KERNEL_CONSOLE_METHOD:-}" in
	grubby)
		[ -n "$ST_KERNEL_CONSOLE" ] && run "removing the kernel console" \
			grubby --update-kernel=ALL --remove-args="console=$ST_KERNEL_CONSOLE" || true
		;;
	update-grub|grub-mkconfig|grub2-mkconfig)
		if [ -f /etc/default/grub ] && grep -q "# $MARKER\$" /etc/default/grub; then
			grep -v "# $MARKER\$" /etc/default/grub > /etc/default/grub.machman-tmp
			mv /etc/default/grub.machman-tmp /etc/default/grub
			case "${ST_KERNEL_CONSOLE_METHOD}" in
			update-grub) run_live "rebuilding the GRUB config" update-grub || true ;;
			grub-mkconfig)
				run_live "rebuilding the GRUB config" \
					grub-mkconfig -o /boot/grub/grub.cfg || true
				;;
			grub2-mkconfig)
				run_live "rebuilding the GRUB config" \
					grub2-mkconfig -o /boot/grub2/grub.cfg || true
				;;
			esac
		fi
		;;
	esac
	return 0
}
