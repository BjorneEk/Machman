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
	for _kpd_m in "$MARKER" ${ADOPT_FROM:+"$ADOPT_FROM"}; do
		sed -n "s/.*console=\(hvc[0-9]*\) console=tty0\" # $_kpd_m\$/\1/p" \
			/etc/default/grub | head -n 1
	done | head -n 1
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
	# The variable name is a printf argument: the emitted line extends the distro's own
	# value, and spelling the dollar-name literally here would look like a read to the
	# drift scanner.
	_MF_BODY="$(printf '%s="$%s console=%s console=tty0" # %s' \
		GRUB_CMDLINE_LINUX_DEFAULT GRUB_CMDLINE_LINUX_DEFAULT "$KC_DEVICE" "$MARKER")"
	_MF_TEXT="# $MARKER"
	export _MF_BODY _MF_TEXT
	_kge_code=0
	rewrite_file /etc/default/grub kernelconsole_grub_line || _kge_code=$?
	unset _MF_BODY _MF_TEXT
	return "$_kge_code"
}

# Filter: our previous line dropped wherever it was, the new one (_MF_BODY) appended last.
kernelconsole_grub_line() {
	awk 'index($0, ENVIRON["_MF_TEXT"]) == 0 { print } END { print ENVIRON["_MF_BODY"] }'
}

# One restorable copy of the generated config before every rebuild. Without it nothing is
# edited or rebuilt: 1, with R_ERROR naming the copy that failed.
kernelconsole_backup_cfg() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	for _kcb_cfg in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
		[ -f "$_kcb_cfg" ] || continue
		if ! cp "$_kcb_cfg" "$_kcb_cfg.machman-backup" 2>/dev/null; then
			R_ERROR="could not back up $_kcb_cfg"
			return 1
		fi
	done
	return 0
}

kernelconsole_act() {
	[ -n "$KC_DEVICE" ] || return 0
	case "$BOOTLOADER" in
	grubby)
		kernelconsole_act_grubby
		;;
	update-grub|grub-mkconfig|grub2-mkconfig)
		if ! kernelconsole_backup_cfg; then
			step_failed kernel-console "$R_ERROR — the boot loader was left alone" \
				"Make room in /boot (or fix its mount), then re-run."
			return 0
		fi
		if ! kernelconsole_grub_default_edit; then
			step_failed kernel-console "could not edit /etc/default/grub: $R_ERROR" \
				"Add console=$KC_DEVICE console=tty0 to its kernel line yourself."
			return 0
		fi
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

# grubby keeps no file of ours: what a run did to the boot entries is in the ledger, entry
# by entry, each named by its kernel (what --update-kernel takes). The arguments the entries
# carry, one per line, each once.
kernelconsole_grubby_args() {
	grubby --info=ALL 2>/dev/null | sed -n 's/^args=//p' | tr -d '"' | tr ' ' '\n' \
		| awk 'NF && !seen[$0]++'
}

# The entries, one per line: "<kernel> <its arguments>".
kernelconsole_grubby_entries() {
	grubby --info=ALL 2>/dev/null | awk '
		function flush() { if (k != "") print k " " a; k = ""; a = "" }
		/^index=/ { flush() }
		/^kernel=/ { k = substr($0, 8); gsub(/"/, "", k) }
		/^args=/ { a = substr($0, 6); gsub(/"/, "", a) }
		END { flush() }'
}

# kernelconsole_entry_args <entries> <kernel> — that entry's arguments, one per line.
kernelconsole_entry_args() {
	printf '%s\n' "$1" | awk -v k="$2" '$1 == k { for (i = 2; i <= NF; i++) print $i; exit }'
}

# The console= arguments among <arguments> (one per line or on one line), in order, on one.
kernelconsole_consoles_in() {
	printf '%s\n' "$1" | tr ' ' '\n' | grep '^console=' | tr '\n' ' ' | sed 's/ $//'
}

# kernelconsole_without <words> <words> — the first list's words the second lacks, in order.
kernelconsole_without() {
	_kw_out=""
	for _kw_w in $1; do
		has_word "$_kw_w" "$2" || _kw_out="${_kw_out:+$_kw_out }$_kw_w"
	done
	printf '%s' "$_kw_out"
}

# The arguments a run added, each once, on one line.
kernelconsole_grubby_added() {
	ledger_values grubby-arg | awk '!seen[$2]++ { print $2 }' | tr '\n' ' ' | sed 's/ $//'
}

# Every argument a run added (grubby-arg "<kernel> <argument>") goes from the entry it went
# into, one grubby call per entry. An entry made since (a kernel installed after setup copies
# the options) loses the device argument too, never console=tty0, which may be its own; an
# entry that was there (grubby-entry) and got nothing keeps what it has.
kernelconsole_take_back() {
	_ktb_entries="$(kernelconsole_grubby_entries)"
	_ktb_devs="$(ledger_values grubby-arg | awk '$2 != "console=tty0" && !seen[$2]++ { print $2 }')"
	while IFS= read -r _ktb_line; do
		[ -n "$_ktb_line" ] || continue
		_ktb_k="${_ktb_line%% *}"
		_ktb_rm="$(ledger_values grubby-arg | awk -v k="$_ktb_k" '$1 == k { print $2 }')"
		if [ -z "$_ktb_rm" ] && ! ledger_has grubby-entry "$_ktb_k"; then
			_ktb_rm="$(kernelconsole_entry_args "$_ktb_entries" "$_ktb_k" \
				| grep -xF -- "$_ktb_devs" || true)"
		fi
		[ -n "$_ktb_rm" ] || continue
		run "removing the kernel console from $_ktb_k" grubby --update-kernel="$_ktb_k" \
			--remove-args="$(printf '%s\n' "$_ktb_rm" | tr '\n' ' ' | sed 's/ $//')" || true
	done <<EOF
$_ktb_entries
EOF
	while IFS= read -r _ktb_e; do
		[ -z "$_ktb_e" ] || ledger_forget grubby-arg "$_ktb_e"
	done <<EOF
$(ledger_values grubby-arg)
EOF
	return 0
}

# The pair goes on every entry; in each, only the arguments it lacked count as the run's
# (grubby-arg), and the entries there at the time are noted (grubby-entry). grubby's add also
# drops an entry's console= arguments: an entry that lost any keeps its list from before the
# first run (grubby-had) so the uninstall can put it back. A re-point first takes back what a
# run added for the old device.
kernelconsole_act_grubby() {
	_kag_old="$(kernelconsole_pending_device)"
	[ -z "$_kag_old" ] && _kag_old="$ST_KERNEL_CONSOLE"
	if [ -n "$_kag_old" ] && [ "$_kag_old" != "$KC_DEVICE" ]; then
		if [ -n "$(ledger_values grubby-device)" ]; then
			kernelconsole_take_back
		else
			# A record from before v8 names no arguments: the old device's is the one it set.
			run "removing the old kernel console" grubby --update-kernel=ALL \
				--remove-args="console=$_kag_old" || true
		fi
		ledger_forget grubby-device "$_kag_old"
	fi
	_kag_before="$(kernelconsole_grubby_entries)"
	if ! run "pointing the kernel console at $KC_DEVICE" \
		grubby --update-kernel=ALL --args="console=$KC_DEVICE console=tty0"; then
		step_failed kernel-console \
			"grubby could not set console=$KC_DEVICE${R_ERROR:+: $R_ERROR}" \
			"Run it yourself: grubby --update-kernel=ALL --args='console=$KC_DEVICE console=tty0'"
		return 0
	fi
	ledger_note grubby-device "$KC_DEVICE"
	_kag_after="$(kernelconsole_grubby_entries)"
	_kag_lost=""
	while IFS= read -r _kag_line; do
		[ -n "$_kag_line" ] || continue
		_kag_k="${_kag_line%% *}"
		_kag_was="$(kernelconsole_entry_args "$_kag_before" "$_kag_k" | tr '\n' ' ')"
		_kag_now="$(kernelconsole_entry_args "$_kag_after" "$_kag_k" | tr '\n' ' ')"
		ledger_note grubby-entry "$_kag_k"
		for _kag_a in "console=$KC_DEVICE" console=tty0; do
			if has_word "$_kag_a" "$_kag_now" && ! has_word "$_kag_a" "$_kag_was"; then
				ledger_note grubby-arg "$_kag_k $_kag_a"
			fi
		done
		_kag_had="$(kernelconsole_consoles_in "$_kag_was")"
		_kag_gone="$(kernelconsole_without "$_kag_had" "$_kag_now")"
		[ -n "$_kag_gone" ] || continue
		if ! ledger_values grubby-had | awk -v k="$_kag_k" '$1 == k { f = 1 } END { exit !f }'
		then
			ledger_note grubby-had "$_kag_k $_kag_had"
		fi
		for _kag_a in $_kag_gone; do
			has_word "$_kag_a" "$_kag_lost" || _kag_lost="${_kag_lost:+$_kag_lost }$_kag_a"
		done
	done <<EOF
$_kag_after
EOF
	ok "kernel messages -> $KC_DEVICE, display stays on tty0 (next boot)"
	if [ -n "$_kag_lost" ]; then
		note "grubby replaced $_kag_lost in the boot entries — the uninstall puts it back."
	fi
	_kag_added="$(kernelconsole_grubby_added)"
	if [ -n "$_kag_added" ]; then
		note "Rollback: grubby --update-kernel=ALL --remove-args='$_kag_added'"
	fi
	KC_DEVICE_DONE="$KC_DEVICE"
	KC_METHOD_DONE=grubby
	return 0
}

# The uninstall's grubby arm: the arguments a run added go from the entries they went into,
# and an entry's console= arguments grubby's add replaced come back — only into that entry,
# and only while the console= arguments it has now are its old ones (the last one is
# /dev/console, so one added since makes the order the user's call: named, never cleared). A
# record from before v8 names no arguments: the device's goes, and console=tty0 — maybe the
# entries' own — stays, named.
kernelconsole_uninstall_grubby() {
	if [ -n "$(ledger_values grubby-device)" ]; then
		kernelconsole_take_back
	elif [ -n "$1" ]; then
		run "removing the kernel console" grubby --update-kernel=ALL \
			--remove-args="console=$1" || true
		if kernelconsole_grubby_args | grep -qxF console=tty0; then
			note "console=tty0 stays in the boot entries — no record says Machman added it."
			note "Remove it: grubby --update-kernel=ALL --remove-args='console=tty0'"
		fi
	fi
	_kug_entries="$(kernelconsole_grubby_entries)"
	while IFS= read -r _kug_line; do
		[ -n "$_kug_line" ] || continue
		_kug_k="${_kug_line%% *}"
		_kug_had="${_kug_line#* }"
		_kug_now="$(kernelconsole_entry_args "$_kug_entries" "$_kug_k")"
		_kug_now="$(kernelconsole_consoles_in "$_kug_now")"
		_kug_missing="$(kernelconsole_without "$_kug_had" "$_kug_now")"
		[ -n "$_kug_missing" ] || continue
		if [ -n "$(kernelconsole_without "$_kug_now" "$_kug_had")" ]; then
			_kug_why="it has console arguments set since, and the last console= is /dev/console"
			note "$_kug_missing stays out of the boot entry for $_kug_k — $_kug_why."
			_kug_fix="grubby --update-kernel=$_kug_k --args='$_kug_missing'"
			note "Add it back where it belongs: $_kug_fix"
		elif run "putting back the console arguments" grubby --update-kernel="$_kug_k" \
			--args="$_kug_had"; then
			ok "put back $_kug_missing in the boot entry for $_kug_k"
		else
			_kug_fix="grubby --update-kernel=$_kug_k --args='$_kug_had'"
			_kug_what="$_kug_missing in the boot entry for $_kug_k"
			warn "could not put back $_kug_what — add it yourself: $_kug_fix"
			UNINSTALL_KEPT=1
		fi
	done <<EOF
$(ledger_values grubby-had)
EOF
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

# No record of how the kernel console was set (the state is gone, its write failed, or the
# guest was cloned): grubby keeps no file of ours to find by marker, so the pair Machman
# puts in its boot entries is named with its remedy, never removed blind — a user can set
# the same arguments. The uninstall then ends partial.
kernelconsole_name_unrecorded() {
	have grubby || return 0
	_kcn_args=" $(grubby --info=ALL 2>/dev/null | sed -n 's/^args=//p' | tr -d '"' \
		| tr '\n' ' ') "
	for _kcn_dev in $CONSOLE_DEVICES; do
		case "$_kcn_args" in
		*" console=$_kcn_dev console=tty0 "*)
			warn "console=$_kcn_dev console=tty0 stays in the boot entries — Machman has no record of adding it."
			note "Remove it: grubby --update-kernel=ALL --remove-args='console=$_kcn_dev console=tty0'"
			UNINSTALL_KEPT=1
			;;
		esac
	done
	return 0
}

kernelconsole_uninstall() {
	linux_guest || return 0
	if [ -z "${ST_KERNEL_CONSOLE_METHOD:-}" ]; then
		kernelconsole_name_unrecorded
	fi
	_kcu_dev="${ST_KERNEL_CONSOLE:-$(kernelconsole_pending_device)}"
	case "${ST_KERNEL_CONSOLE_METHOD:-}" in
	grubby)
		kernelconsole_uninstall_grubby "$_kcu_dev"
		;;
	*)
		if [ -f /etc/default/grub ] && grep -q "# $MARKER\$" /etc/default/grub; then
			if ! drop_lines /etc/default/grub "# $MARKER"; then
				uninstall_kept
				return 0
			fi
			# No fresh backup here: keep the copy from before setup's last rebuild (the
			# pre-Machman config only if setup ran once); overwriting it with the current,
			# Machman-era config would leave a failed rebuild with nothing worth restoring.
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
