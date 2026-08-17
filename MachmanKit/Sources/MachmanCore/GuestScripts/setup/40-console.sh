# === machman-setup: 40-console ===
# Feature: login prompts on the VM's virtio consoles. Detection is live (is a getty on
# the port NOW; is one persistent for the next boot) — distro tables lie, running
# processes do not. systemd's getty-generator gives hvc0 a login on its own when the
# device exists; that shows up as "active (automatic)" and is left alone.

CONSOLE_DEVICES=""         # expected device names, space-separated
CONSOLE_SELECTED=""        # devices chosen for a login, space-separated
CONSOLE_PLAN=""
F_AVAIL_console=0
F_REASON_console=""
GETTY_MECH="none"          # systemd | launchd | inittab | runit | freebsd-rc | none
LAUNCHD_GETTY_PREFIX="com.machman.console-getty"

console_detect() {
	CONSOLE_DEVICES=""
	_cd_i=0
	while [ "$_cd_i" -lt "${CONSOLE_COUNT:-0}" ]; do
		CONSOLE_DEVICES="$CONSOLE_DEVICES $(console_device "$_cd_i")"
		_cd_i=$((_cd_i + 1))
	done
	CONSOLE_DEVICES="${CONSOLE_DEVICES# }"
	case "$INIT" in
	systemd) GETTY_MECH=systemd ;;
	launchd) GETTY_MECH=launchd ;;
	runit) GETTY_MECH=runit ;;
	freebsd-rc) GETTY_MECH=freebsd-rc ;;
	inittab) GETTY_MECH=inittab ;;
	openrc|sysv) [ -f /etc/inittab ] && GETTY_MECH=inittab || GETTY_MECH=none ;;
	*) GETTY_MECH=none ;;
	esac
	verbose detect "consoles=[${CONSOLE_DEVICES:-none}] getty-mech=$GETTY_MECH"
	return 0
}

# One console's login state: active | active-auto | configured | none | missing.
console_login_state() {
	if ! [ -e "/dev/$1" ]; then
		echo missing
		return 0
	fi
	if getty_active_on "$1"; then
		if [ "$GETTY_MECH" = systemd ] \
			&& ! systemctl is-enabled "serial-getty@$1.service" >/dev/null 2>&1; then
			echo active-auto
		else
			echo active
		fi
		return 0
	fi
	if getty_persistent_on "$1"; then
		echo configured
	else
		echo none
	fi
	return 0
}

console_available() {
	F_AVAIL_console=0
	F_REASON_console=""
	if [ "${CONSOLE_COUNT:-0}" -eq 0 ]; then
		F_REASON_console="no consoles attached — add one in Machman first"
		return 0
	fi
	case "$OS_FAMILY" in
	openbsd)
		F_REASON_console="OpenBSD has no virtio-console driver"
		return 0
		;;
	freebsd)
		# The device only exists once virtio_console.ko is loaded; loading is part of
		# the act, so availability is about the loader, not the device.
		if ! kldstat 2>/dev/null | grep -q virtio_console \
			&& ! kldload -n virtio_console 2>/dev/null; then
			F_REASON_console="no virtio_console driver in this FreeBSD"
			return 0
		fi
		;;
	esac
	if [ "$GETTY_MECH" = none ]; then
		F_REASON_console="no known way to configure a login under init '$INIT'"
		return 0
	fi
	F_AVAIL_console=1
	return 0
}

# One menu line per console, annotated with what is already true.
console_menu_lines() {
	for _cml_dev in $CONSOLE_DEVICES; do
		case "$(console_login_state "$_cml_dev")" in
		active-auto) echo "$_cml_dev   login active (automatic)" ;;
		active) echo "$_cml_dev   login active" ;;
		configured) echo "$_cml_dev   login configured (next boot)" ;;
		missing) echo "$_cml_dev   device not present in this guest" ;;
		*) echo "$_cml_dev   no login" ;;
		esac
	done
}

console_decide() {
	CONSOLE_SELECTED=""
	if [ -n "$CONSOLES_OVERRIDE" ]; then
		CONSOLE_SELECTED="$CONSOLES_OVERRIDE"
	elif [ "$(printf '%s\n' "$CONSOLE_DEVICES" | wc -w | tr -d ' ')" = "1" ]; then
		CONSOLE_SELECTED="$CONSOLE_DEVICES"
	else
		# Default ON: every console that has no login yet (present or not — the act
		# re-checks); previously configured ones stay ON so re-runs verify them.
		_cdc_marks=""
		_cdc_i=1
		for _cdc_dev in $CONSOLE_DEVICES; do
			case "$(console_login_state "$_cdc_dev")" in
			none|missing) toggle_mark "$_cdc_marks" "$_cdc_i"; _cdc_marks="$R_MARKS" ;;
			*)
				if state_was_configured console \
					&& has_word "$_cdc_dev" "$ST_CONSOLE_LOGINS"; then
					toggle_mark "$_cdc_marks" "$_cdc_i"
					_cdc_marks="$R_MARKS"
				fi
				;;
			esac
			_cdc_i=$((_cdc_i + 1))
		done
		menu_multi "Configure a login on which consoles?" \
			"$(console_menu_lines)" "$_cdc_marks"
		_cdc_i=1
		for _cdc_dev in $CONSOLE_DEVICES; do
			case ",$R_MARKS," in
			*",$_cdc_i,"*) CONSOLE_SELECTED="$CONSOLE_SELECTED $_cdc_dev" ;;
			esac
			_cdc_i=$((_cdc_i + 1))
		done
		CONSOLE_SELECTED="${CONSOLE_SELECTED# }"
	fi
	CONSOLE_PLAN=""
	for _cdc_dev in $CONSOLE_SELECTED; do
		case "$(console_login_state "$_cdc_dev")" in
		active|active-auto) _cdc_what="already active" ;;
		configured) _cdc_what="already configured" ;;
		*) _cdc_what="enable ($GETTY_MECH)" ;;
		esac
		CONSOLE_PLAN="$CONSOLE_PLAN$_cdc_dev ($_cdc_what) · "
	done
	CONSOLE_PLAN="${CONSOLE_PLAN% · }"
	[ -n "$CONSOLE_PLAN" ] || CONSOLE_PLAN="none selected"
	return 0
}

console_plan() {
	plan_line "consoles" "$CONSOLE_PLAN"
	return 0
}

# --------------------------------------------------------------------- per-mechanism ----

console_act_systemd() {
	case "$(console_login_state "$1")" in
	active|active-auto) ok "login on $1 is already active"; return 0 ;;
	esac
	if run "enabling a login on $1" systemctl enable --now "serial-getty@$1.service"; then
		ok "login enabled on $1"
	else
		step_failed console "could not enable serial-getty@$1${R_ERROR:+: $R_ERROR}" \
			"Enable it yourself: systemctl enable --now serial-getty@$1"
	fi
	return 0
}

console_act_inittab() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add a getty line for $1 to /etc/inittab"
		return 0
	fi
	if have agetty; then
		_cai_line="T${2}:2345:respawn:$(command -v agetty) -L $1 115200 vt100"
	else
		_cai_line="$1::respawn:/sbin/getty 38400 $1"
	fi
	printf '%s\n' "$_cai_line" >> /etc/inittab.machman-add
	return 0
}

console_act_runit() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would create /etc/sv/agetty-$1 and link it into /var/service"
		return 0
	fi
	if ! have agetty; then
		step_failed console "agetty is missing — no login service for $1" \
			"Install util-linux, then re-run."
		return 0
	fi
	mkdir -p "/etc/sv/agetty-$1"
	{
		printf '#!/bin/sh\n# %s\nexec agetty %s 115200 vt100\n' "$MARKER" "$1"
	} > "/etc/sv/agetty-$1/run"
	chmod 755 "/etc/sv/agetty-$1/run"
	if [ ! -e "/var/service/agetty-$1" ]; then
		run "enabling a login on $1" ln -s "/etc/sv/agetty-$1" /var/service/ \
			|| step_failed console "could not link agetty-$1 into /var/service" \
				"Link it yourself: ln -s /etc/sv/agetty-$1 /var/service/"
	fi
	ok "login enabled on $1"
	return 0
}

console_act_freebsd() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add a getty line for $1 to /etc/ttys"
		return 0
	fi
	printf '%s "/usr/libexec/getty 3wire" vt100 onifexists secure\n' "$1" \
		>> /etc/ttys.machman-add
	return 0
}

console_act_launchd() {
	if [ ! -e "/dev/$1" ]; then
		step_failed console "/dev/$1 is not present in this guest — skipped" \
			"Boot with the console attached, then re-run."
		return 0
	fi
	_cal_plist="/Library/LaunchDaemons/$LAUNCHD_GETTY_PREFIX.$2.plist"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would install $_cal_plist for $1"
		return 0
	fi
	cat > "$_cal_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCHD_GETTY_PREFIX.$2</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/libexec/getty</string>
		<string>std.115200</string>
		<string>$1</string>
	</array>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
PLIST
	chown root:wheel "$_cal_plist"
	chmod 644 "$_cal_plist"
	run "starting the login on $1" launchctl bootstrap system "$_cal_plist" || true
	ok "login installed on $1"
	return 0
}

# Marker-scoped batch edits: the inittab/ttys lines collect in a staging file, then land
# between BEGIN/END markers in one strip-and-append (idempotent re-runs, exact uninstall).
console_flush_lines() {
	_cfl_file="$1"
	_cfl_add="$1.machman-add"
	[ -f "$_cfl_add" ] || return 0
	strip_block "$_cfl_file"
	{
		printf '# BEGIN %s\n' "$MARKER"
		cat "$_cfl_add"
		printf '# END %s\n' "$MARKER"
	} >> "$_cfl_file"
	rm -f "$_cfl_add"
	return 0
}

console_act() {
	[ -n "$CONSOLE_SELECTED" ] || return 0
	if [ "$OS_FAMILY" = freebsd ]; then
		if ! kldstat 2>/dev/null | grep -q virtio_console; then
			run "loading the virtio console driver" kldload virtio_console \
				|| step_failed console "could not load virtio_console" \
					"Load it yourself: kldload virtio_console"
		fi
		if ! sysrc -n kld_list 2>/dev/null | grep -q virtio_console; then
			run "keeping virtio_console across reboots" sysrc "kld_list+=virtio_console" \
				|| true
		fi
	fi
	rm -f /etc/inittab.machman-add /etc/ttys.machman-add 2>/dev/null || true
	_ca_i=0
	for _ca_dev in $CONSOLE_SELECTED; do
		# A respawning getty on an absent device is a churn loop (systemd's unit binds the
		# device and waits; launchd checks below) — skip what is not there and say so.
		case "$GETTY_MECH" in
		inittab|runit|freebsd-rc)
			if [ ! -e "/dev/$_ca_dev" ] && [ "$DRY_RUN" -eq 0 ]; then
				step_failed console "/dev/$_ca_dev is not present in this guest — skipped" \
					"Boot with the console attached, then re-run."
				_ca_i=$((_ca_i + 1))
				continue
			fi
			;;
		esac
		case "$GETTY_MECH" in
		systemd) console_act_systemd "$_ca_dev" ;;
		inittab) console_act_inittab "$_ca_dev" "$_ca_i" ;;
		runit) console_act_runit "$_ca_dev" ;;
		freebsd-rc) console_act_freebsd "$_ca_dev" ;;
		launchd) console_act_launchd "$_ca_dev" "$_ca_i" ;;
		esac
		_ca_i=$((_ca_i + 1))
	done
	if [ "$DRY_RUN" -eq 0 ]; then
		case "$GETTY_MECH" in
		inittab)
			if [ -f /etc/inittab.machman-add ]; then
				console_flush_lines /etc/inittab
				run "reloading init" kill -HUP 1 || true
				ok "logins land in /etc/inittab"
			fi
			;;
		freebsd-rc)
			if [ -f /etc/ttys.machman-add ]; then
				console_flush_lines /etc/ttys
				run "reloading init" kill -HUP 1 || true
				ok "logins land in /etc/ttys"
			fi
			;;
		esac
	fi
	return 0
}

console_report() {
	_cr_i=1
	for _cr_dev in $CONSOLE_DEVICES; do
		_cr_state="$(console_login_state "$_cr_dev")"
		case "$_cr_state" in
		active-auto) _cr_out="$_cr_dev active auto" ;;
		active) _cr_out="$_cr_dev active" ;;
		configured) _cr_out="$_cr_dev configured" ;;
		missing) _cr_out="$_cr_dev missing" ;;
		*) _cr_out="$_cr_dev none" ;;
		esac
		if has_word "$_cr_dev" "$CMDLINE_CONSOLES"; then
			_cr_out="$_cr_out kernel"
		fi
		printf 'CONSOLE_%s=%s\n' "$_cr_i" "$_cr_out"
		_cr_i=$((_cr_i + 1))
	done
	return 0
}

console_uninstall() {
	case "$GETTY_MECH" in
	systemd)
		# Only what a run of this script would have enabled: the explicit units.
		for _cu_dev in $CONSOLE_DEVICES; do
			if systemctl is-enabled "serial-getty@$_cu_dev.service" >/dev/null 2>&1; then
				run "disabling the login on $_cu_dev" \
					systemctl disable --now "serial-getty@$_cu_dev.service" || true
			fi
		done
		;;
	inittab)
		strip_block /etc/inittab
		kill -HUP 1 2>/dev/null || true
		;;
	freebsd-rc)
		strip_block /etc/ttys
		kill -HUP 1 2>/dev/null || true
		;;
	runit)
		for _cu_sv in /etc/sv/agetty-*; do
			[ -e "$_cu_sv" ] || continue
			grep -q "$MARKER" "$_cu_sv/run" 2>/dev/null || continue
			rm -f "/var/service/$(basename "$_cu_sv")"
			rm -rf "$_cu_sv"
		done
		;;
	launchd)
		for _cu_plist in "/Library/LaunchDaemons/$LAUNCHD_GETTY_PREFIX".*.plist; do
			[ -e "$_cu_plist" ] || continue
			launchctl bootout "system/$(basename "$_cu_plist" .plist)" 2>/dev/null || true
			rm -f "$_cu_plist"
		done
		;;
	esac
	return 0
}
