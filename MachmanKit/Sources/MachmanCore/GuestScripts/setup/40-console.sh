# === machman-setup: 40-console ===
# Feature: login prompts on the VM's virtio consoles. Detection is live (is a getty on
# the port NOW; is one persistent for the next boot) — distro tables lie, running
# processes do not — and OWNERSHIP-aware: a login configured outside Machman (no marker)
# is never touched blind. Per console the plan carries a verb: install, verify, adopt
# (comment the existing line, tagged for restore, and manage a marked one), or report
# only. systemd's getty-generator gives hvc0 a login on its own; that shows up as
# "active (automatic)" and is left alone.

CONSOLE_DEVICES=""         # expected device names, space-separated
CONSOLE_SELECTED=""        # devices chosen for this run, space-separated
CONSOLE_MANAGED=""         # devices this run manages (for the state file)
CONSOLE_ACTIONS=""         # "dev=install dev=verify dev=adopt dev=report dev=auto"
CONSOLE_PLAN=""
avail_console=0
reason_console=""
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

# The device name as an ERE fragment (ttyV0.0 carries dots).
console_dev_esc() {
	printf '%s' "$1" | sed 's/\./\\./g'
}

# Is a matching line inside OUR marker block? <file> <awk ERE>
console_line_in_block() {
	[ -f "$1" ] || return 1
	awk -v re="$2" -v m="$MARKER" '
		$0 == "# BEGIN " m { inb = 1; next }
		$0 == "# END " m { inb = 0; next }
		inb && $0 ~ re { found = 1 }
		END { exit found ? 0 : 1 }
	' "$1"
}

# The ERE matching a getty entry for this device in inittab-style files.
console_inittab_re() {
	printf 'getty.*[^a-zA-Z0-9]%s([^0-9]|$)' "$(console_dev_esc "$1")"
}

# Who owns the persistent login: ours (marker-managed, or attributable to us) | foreign
# (configured, but not by this script) | none. systemd enablement is unattributable but
# also duplication-free, so it counts as ours; launchd persistence is only ever probed
# through our own plist labels.
console_ownership() {
	getty_persistent_on "$1" || { echo none; return 0; }
	case "$GETTY_MECH" in
	systemd|launchd) echo ours ;;
	inittab)
		if console_line_in_block /etc/inittab "$(console_inittab_re "$1")"; then
			echo ours
		else
			echo foreign
		fi
		;;
	freebsd-rc)
		if console_line_in_block /etc/ttys "^$(console_dev_esc "$1")[[:space:]]"; then
			echo ours
		else
			echo foreign
		fi
		;;
	runit)
		if grep -q "$MARKER" "/etc/sv/agetty-$1/run" 2>/dev/null; then
			echo ours
		else
			echo foreign
		fi
		;;
	*) echo foreign ;;
	esac
	return 0
}

console_available() {
	avail_console=0
	reason_console=""
	if [ "${CONSOLE_COUNT:-0}" -eq 0 ]; then
		reason_console="no consoles attached — add one in Machman first"
		return 0
	fi
	case "$OS_FAMILY" in
	openbsd)
		reason_console="OpenBSD has no virtio-console driver"
		return 0
		;;
	freebsd)
		# The device only exists once virtio_console.ko is loaded; loading is part of
		# the act, so availability is about the loader, not the device.
		if ! kldstat 2>/dev/null | grep -q virtio_console \
			&& ! kldload -n virtio_console 2>/dev/null; then
			reason_console="no virtio_console driver in this FreeBSD"
			return 0
		fi
		;;
	esac
	if [ "$GETTY_MECH" = none ]; then
		reason_console="no known way to configure a login under init '$INIT'"
		return 0
	fi
	avail_console=1
	return 0
}

console_is_configured() {
	for _cic_dev in $CONSOLE_DEVICES; do
		case "$(console_login_state "$_cic_dev")" in
		active|active-auto|configured) return 0 ;;
		esac
	done
	return 1
}

# The one-line annotation for the feature menu: the worst case first.
console_menu_note() {
	_cmn_foreign=""
	_cmn_ours=""
	_cmn_todo=0
	_cmn_auto=0
	for _cmn_dev in $CONSOLE_DEVICES; do
		case "$(console_login_state "$_cmn_dev")" in
		active-auto) _cmn_auto=$((_cmn_auto + 1)) ;;
		active|configured)
			if [ "$(console_ownership "$_cmn_dev")" = foreign ]; then
				_cmn_foreign="$_cmn_foreign $_cmn_dev"
			else
				_cmn_ours="$_cmn_ours $_cmn_dev"
			fi
			;;
		*) _cmn_todo=$((_cmn_todo + 1)) ;;
		esac
	done
	# Per-state segments, so mixed truths read whole: "hvc0 managed · 1 to set up".
	_cmn_out=""
	[ -n "$_cmn_ours" ] && _cmn_out="${_cmn_ours# } managed"
	if [ -n "$_cmn_foreign" ]; then
		_cmn_f="${_cmn_foreign# } configured outside Machman — adopt or report"
		_cmn_out="${_cmn_out:+$_cmn_out $G_SEP }$_cmn_f"
	fi
	if [ "$_cmn_todo" -gt 0 ]; then
		_cmn_out="${_cmn_out:+$_cmn_out $G_SEP }$_cmn_todo to set up"
	fi
	if [ -z "$_cmn_out" ]; then
		if [ "$_cmn_auto" -gt 0 ]; then
			_cmn_out="automatic (systemd) — nothing to do"
		else
			_cmn_out="set up logins"
		fi
	fi
	echo "$_cmn_out"
	return 0
}

console_menu_default() {
	# ON unless every console already has its automatic login.
	for _cmd_dev in $CONSOLE_DEVICES; do
		[ "$(console_login_state "$_cmd_dev")" = active-auto ] || { echo 1; return 0; }
	done
	echo 0
	return 0
}

# One menu line per console, annotated with what is already true.
console_menu_lines() {
	for _cml_dev in $CONSOLE_DEVICES; do
		case "$(console_login_state "$_cml_dev")" in
		active-auto) echo "$_cml_dev	login active (automatic)" ;;
		active|configured)
			if [ "$(console_ownership "$_cml_dev")" = foreign ]; then
				echo "$_cml_dev	configured outside Machman — adopt or report"
			else
				echo "$_cml_dev	managed by Machman — verify"
			fi
			;;
		missing) echo "$_cml_dev	device not present in this guest" ;;
		*) echo "$_cml_dev	no login — set up" ;;
		esac
	done
	return 0
}

console_action_of() { # <dev> → the recorded action
	for _cao_pair in $CONSOLE_ACTIONS; do
		case "$_cao_pair" in
		"$1="*) printf '%s' "${_cao_pair#*=}"; return 0 ;;
		esac
	done
	printf 'install'
	return 0
}

console_decide() {
	CONSOLE_SELECTED=""
	if [ -n "$CONSOLES_OVERRIDE" ]; then
		CONSOLE_SELECTED="$CONSOLES_OVERRIDE"
	elif [ "$(printf '%s\n' "$CONSOLE_DEVICES" | wc -w | tr -d ' ')" = "1" ]; then
		# One console: nothing to pick — the per-device ACTION below still decides what
		# actually happens (verify/adopt/report, never a blind re-install).
		CONSOLE_SELECTED="$CONSOLE_DEVICES"
	else
		_cdc_marks=""
		_cdc_i=1
		for _cdc_dev in $CONSOLE_DEVICES; do
			[ "$(console_login_state "$_cdc_dev")" = active-auto ] || {
				toggle_mark "$_cdc_marks" "$_cdc_i"
				_cdc_marks="$R_MARKS"
			}
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
	# The verb per selected device — what this run WILL do, shown before it does it.
	# CONSOLE_MANAGED collects the devices WE manage after this run (install/verify/
	# adopt) — report-only and automatic ones are not ours and stay out of the state.
	CONSOLE_ACTIONS=""
	CONSOLE_MANAGED=""
	CONSOLE_PLAN=""
	for _cdc_dev in $CONSOLE_SELECTED; do
		case "$(console_login_state "$_cdc_dev")" in
		active-auto)
			_cdc_act=auto
			_cdc_what="automatic — nothing to do"
			;;
		active|configured)
			if [ "$(console_ownership "$_cdc_dev")" = foreign ]; then
				if [ "$GETTY_MECH" = runit ]; then
					# Someone else's service dir is not ours to take over.
					_cdc_act=report
					_cdc_what="report only — configured outside Machman"
				else
					menu_select \
						"$_cdc_dev already has a login not managed by Machman:" \
"Leave it — report only
Adopt — comment the existing line (restorable) and manage a marked one" 1
					if [ "$R_INDEX" = 2 ]; then
						_cdc_act=adopt
						_cdc_what="adopt — supersede the existing line"
					else
						_cdc_act=report
						_cdc_what="report only — configured outside Machman"
					fi
				fi
			else
				_cdc_act=verify
				_cdc_what="verify — no changes expected"
			fi
			;;
		*)
			_cdc_act=install
			_cdc_what="install ($GETTY_MECH)"
			;;
		esac
		CONSOLE_ACTIONS="$CONSOLE_ACTIONS $_cdc_dev=$_cdc_act"
		case "$_cdc_act" in
		install|verify|adopt) CONSOLE_MANAGED="$CONSOLE_MANAGED $_cdc_dev" ;;
		esac
		CONSOLE_PLAN="$CONSOLE_PLAN$_cdc_dev ($_cdc_what) · "
	done
	CONSOLE_ACTIONS="${CONSOLE_ACTIONS# }"
	CONSOLE_MANAGED="${CONSOLE_MANAGED# }"
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
	if run "enabling a login on $1" systemctl enable --now "serial-getty@$1.service"; then
		ok "login enabled on $1"
	else
		step_failed console "could not enable serial-getty@$1${R_ERROR:+: $R_ERROR}" \
			"Enable it yourself: systemctl enable --now serial-getty@$1"
	fi
	return 0
}

# Which init PARSES /etc/inittab picks the line format — never which getty binary exists:
# busybox init reads the id field as a device under /dev/ (a sysvinit-style "T0:" id makes
# it respawn-loop on /dev/T0), sysvinit reads it as a free label. PID 1 tells the truth;
# /sbin/init is the fallback for the no-/proc edge.
console_inittab_is_busybox() {
	_cib_exe="$(readlink /proc/1/exe 2>/dev/null)" || _cib_exe=""
	[ -n "$_cib_exe" ] || { _cib_exe="$(readlink /sbin/init 2>/dev/null)" || _cib_exe=""; }
	case "$_cib_exe" in
	*busybox*) return 0 ;;
	esac
	return 1
}

console_act_inittab() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add a getty line for $1 to /etc/inittab"
		return 0
	fi
	if console_inittab_is_busybox; then
		# busybox: the id field IS the device; agetty still serves the login when present.
		if have agetty; then
			_cai_line="$1::respawn:$(command -v agetty) -L $1 115200 vt100"
		else
			_cai_line="$1::respawn:/sbin/getty 38400 $1"
		fi
	elif have agetty; then
		# sysvinit wants a unique 1-4 char id; M<n> stays clear of the distros' own
		# T0/T1 serial entries.
		_cai_line="M${2}:2345:respawn:$(command -v agetty) -L $1 115200 vt100"
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

# The install arm for one device (adopt falls through here after superseding).
console_install_one() {
	# A respawning getty on an absent device is a churn loop (systemd's unit binds the
	# device and waits; launchd checks itself) — skip what is not there and say so.
	case "$GETTY_MECH" in
	inittab|runit|freebsd-rc)
		if [ ! -e "/dev/$1" ] && [ "$DRY_RUN" -eq 0 ]; then
			step_failed console "/dev/$1 is not present in this guest — skipped" \
				"Boot with the console attached, then re-run."
			return 0
		fi
		;;
	esac
	case "$GETTY_MECH" in
	systemd) console_act_systemd "$1" ;;
	inittab) console_act_inittab "$1" "$2" ;;
	runit) console_act_runit "$1" ;;
	freebsd-rc) console_act_freebsd "$1" ;;
	launchd) console_act_launchd "$1" "$2" ;;
	esac
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
	_ca_flush=0
	for _ca_dev in $CONSOLE_SELECTED; do
		case "$(console_action_of "$_ca_dev")" in
		auto)
			ok "$_ca_dev: automatic login (systemd) — nothing to do"
			;;
		verify)
			if getty_persistent_on "$_ca_dev"; then
				ok "login on $_ca_dev verified"
			else
				# Drifted since detection (or the state file lied): reinstall.
				console_install_one "$_ca_dev" "$_ca_i"
				_ca_flush=1
			fi
			;;
		report)
			note "$_ca_dev left as is (configured outside Machman)."
			;;
		adopt)
			if [ "$DRY_RUN" -eq 1 ]; then
				acting "would supersede the existing $_ca_dev line and manage a marked one"
			else
				case "$GETTY_MECH" in
				inittab)
					supersede_lines /etc/inittab "$(console_inittab_re "$_ca_dev")" ;;
				freebsd-rc)
					supersede_lines /etc/ttys \
						"^$(console_dev_esc "$_ca_dev")[[:space:]]" ;;
				esac
				ok "adopted $_ca_dev — the original line is tagged and restorable"
			fi
			console_install_one "$_ca_dev" "$_ca_i"
			_ca_flush=1
			;;
		install)
			console_install_one "$_ca_dev" "$_ca_i"
			_ca_flush=1
			;;
		esac
		_ca_i=$((_ca_i + 1))
	done
	if [ "$DRY_RUN" -eq 0 ] && [ "$_ca_flush" -eq 1 ]; then
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
		case "$_cr_state" in
		active|configured)
			[ "$(console_ownership "$_cr_dev")" = foreign ] \
				&& _cr_out="$_cr_out external"
			;;
		esac
		if has_word "$_cr_dev" "$CMDLINE_CONSOLES"; then
			_cr_out="$_cr_out kernel"
		else
			# Configured-but-not-rebooted kernel console: the chip shows "(next boot)".
			_cr_pend="$KC_DEVICE_DONE"
			[ -z "$_cr_pend" ] && _cr_pend="$(kernelconsole_pending_device)"
			[ -z "$_cr_pend" ] && _cr_pend="${ST_KERNEL_CONSOLE:-}"
			[ "$_cr_pend" = "$_cr_dev" ] && _cr_out="$_cr_out kernel-next"
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
		restore_superseded /etc/inittab
		kill -HUP 1 2>/dev/null || true
		;;
	freebsd-rc)
		strip_block /etc/ttys
		restore_superseded /etc/ttys
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
