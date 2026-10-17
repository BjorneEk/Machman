# === machman-setup: 40-console ===
# Feature: login prompts on the VM's virtio consoles. Detection is live (is a getty on
# the port NOW; is one persistent for the next boot) — distro tables lie, running
# processes do not — and OWNERSHIP-aware: a login configured outside Machman (no marker)
# is never touched blind. Per console the plan carries a verb: install, verify, adopt
# (comment the existing line, tagged for restore, and manage a marked one), report only,
# or keep — a login set up outside Machman that cannot be adopted (a systemd unit, a runit
# service) is checked like Machman's own, but never recorded as Machman's, so the
# uninstall leaves it on. systemd's getty-generator gives hvc0 a login on its own; that
# shows up as "active (automatic)" and is left alone. The act (each init's mechanism) is
# 41-console-mech.

CONSOLE_DEVICES=""         # expected device names, space-separated
CONSOLE_SELECTED=""        # devices chosen for this run, space-separated
CONSOLE_MANAGED=""         # devices this run manages (for the state file)
CONSOLE_ACTIONS=""         # "dev=install dev=verify dev=adopt dev=report dev=keep dev=auto"
CONSOLE_PLAN=""
avail_console=0
reason_console=""
GETTY_MECH="none"          # systemd | launchd | inittab | runit | ttys | none
LAUNCHD_GETTY_PREFIX="com.machman.console-getty"
CONSOLE_STAGE=""           # inittab/ttys lines staged for the marker block, one per line
CONSOLE_STAGED_DEVS=""     # the devices those lines serve, space-separated

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
	freebsd-rc|netbsd-rc|openbsd-rc) GETTY_MECH=ttys ;;
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
		if [ "$GETTY_MECH" = systemd ] && ! getty_unit_enabled "$1"; then
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
# (configured, but not by this script) | none. systemd enablement names no owner, so a
# unit is ours only when a run of this script enabled it (the state lists it), as runit's
# links; launchd persistence is only ever probed through our own plist labels.
console_ownership() {
	getty_persistent_on "$1" || { echo none; return 0; }
	case "$GETTY_MECH" in
	systemd)
		if has_word "$1" "$ST_CONSOLE_LOGINS"; then echo ours; else echo foreign; fi
		;;
	launchd) echo ours ;;
	inittab)
		if console_line_in_block /etc/inittab "$(console_inittab_re "$1")"; then
			echo ours
		else
			echo foreign
		fi
		;;
	ttys)
		if console_line_in_block /etc/ttys "^$(console_dev_esc "$1")[[:space:]]"; then
			echo ours
		else
			echo foreign
		fi
		;;
	runit)
		# Ours: the Machman-named service, an older Machman's own agetty-<dev>, or Void's
		# stock one that a run of this script linked in (the state says so).
		if console_runit_own "$1" || console_runit_legacy "$1" \
			|| { [ "$(readlink "$RUNIT_SERVICE_DIR/agetty-$1" 2>/dev/null)" \
				= "$RUNIT_SV_DIR/agetty-$1" ] && has_word "$1" "$ST_CONSOLE_LOGINS"; }
		then
			echo ours
		else
			echo foreign
		fi
		;;
	*) echo foreign ;;
	esac
	return 0
}

# Any expected console device already in /dev — the driver is unmistakably present
# (covers kernels with virtio_console compiled in, which kldstat's file list misses).
console_any_device_present() {
	for _cdp_dev in $CONSOLE_DEVICES; do
		[ -e "/dev/$_cdp_dev" ] && return 0
	done
	return 1
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
		# viocon(4) came to OpenBSD in 5.9; whether this kernel carries it, its boot
		# messages say (without it the console device is left "not configured").
		if ! console_any_device_present \
			&& ! { cat /var/run/dmesg.boot; dmesg; } 2>/dev/null | grep -q '^viocon[0-9]'
		then
			reason_console="no viocon console driver in this OpenBSD kernel"
			return 0
		fi
		;;
	freebsd)
		# Loading is part of the ACT (console_act does it, reported): this probe must
		# not touch the loader — kldload -n means skip-if-loaded, not dry-run, so it
		# mutated on --dry-run and on every boot-hook --report-only pass, and misread
		# EPERM as "no driver" when probing non-root. Present = already loaded, a
		# console device attached, or the module on disk.
		if ! kldstat 2>/dev/null | grep -q virtio_console \
			&& ! console_any_device_present \
			&& [ ! -f /boot/kernel/virtio_console.ko ] \
			&& [ ! -f /boot/modules/virtio_console.ko ]; then
			reason_console="no virtio_console driver in this FreeBSD"
			return 0
		fi
		;;
	netbsd)
		# viocon(4) arrived in NetBSD 10, compiled in: a console device, or the version.
		if ! console_any_device_present && [ "${OS_VERSION%%.*}" -lt 10 ] 2>/dev/null; then
			reason_console="NetBSD before 10 has no virtio-console driver"
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

# Whether a login set up outside Machman may be adopted: where a shared file holds its line
# (inittab, ttys), adopting comments that line out for a marked one. A unit or service dir
# someone else enabled is not ours to take over: such a login is listed and checked like
# Machman's own and kept — never asked about, never disabled by the uninstall.
console_adoptable() {
	case "$GETTY_MECH" in
	inittab|ttys) return 0 ;;
	esac
	return 1
}

# What a run may do with a login set up outside Machman.
console_foreign_note() {
	if console_adoptable; then
		echo "configured outside Machman — adopt or report"
	else
		echo "set up outside Machman — verify"
	fi
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
		_cmn_f="${_cmn_foreign# } $(console_foreign_note)"
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
				echo "$_cml_dev	$(console_foreign_note)"
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
	# adopt) — report-only, kept and automatic ones are not ours and stay out of the state.
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
				if ! console_adoptable; then
					_cdc_act=keep
					_cdc_what="verify — set up outside Machman"
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
		# One console per line: plan_line puts each under the first.
		CONSOLE_PLAN="${CONSOLE_PLAN:+$CONSOLE_PLAN
}$_cdc_dev ($_cdc_what)"
	done
	CONSOLE_ACTIONS="${CONSOLE_ACTIONS# }"
	CONSOLE_MANAGED="${CONSOLE_MANAGED# }"
	# Logins an earlier run set up on consoles this run leaves alone stay managed (their
	# lines stay too), so the state keeps listing them.
	for _cdc_dev in $ST_CONSOLE_LOGINS; do
		if ! has_word "$_cdc_dev" "$CONSOLE_SELECTED" \
			&& ! has_word "$_cdc_dev" "$CONSOLE_MANAGED" && getty_persistent_on "$_cdc_dev"
		then
			CONSOLE_MANAGED="${CONSOLE_MANAGED:+$CONSOLE_MANAGED }$_cdc_dev"
		fi
	done
	[ -n "$CONSOLE_PLAN" ] || CONSOLE_PLAN="none selected"
	return 0
}

console_plan() {
	plan_line "consoles" "$CONSOLE_PLAN"
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
		# External: a login left alone where it could have been adopted. One a unit or
		# service dir keeps reads like Machman's own (the uninstall still leaves it on).
		case "$_cr_state" in
		active|configured)
			console_adoptable && [ "$(console_ownership "$_cr_dev")" = foreign ] \
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

# The console this run's session hangs off, if any: the terminal of this shell or of any
# ancestor — sudo's use_pty gives the script a pseudo-terminal of its own while the login
# stays on the console. Linux reads /proc (busybox ps has no -p); elsewhere ps names each
# one. console_session_device [proc root] → the device, or nothing.
console_session_device() {
	[ -n "$CONSOLE_DEVICES" ] || return 0
	_csd_proc="${1:-/proc}"
	_csd_pid=$$
	_csd_n=0
	while [ "$_csd_n" -lt 32 ]; do
		if [ -d "$_csd_proc/$_csd_pid" ]; then
			_csd_ttys="$(for _csd_fd in 0 1 2; do
				readlink "$_csd_proc/$_csd_pid/fd/$_csd_fd" 2>/dev/null
			done | tr '\n' ' ')"
			# stat is "pid (comm) state ppid …", and comm may itself hold ") ".
			_csd_ppid="$(sed 's/.*) //' "$_csd_proc/$_csd_pid/stat" 2>/dev/null \
				| cut -d ' ' -f 2)"
		else
			_csd_ttys="/dev/$(ps -o tty= -p "$_csd_pid" 2>/dev/null | tr -d ' ')"
			_csd_ppid="$(ps -o ppid= -p "$_csd_pid" 2>/dev/null | tr -d ' ')"
		fi
		for _csd_dev in $CONSOLE_DEVICES; do
			if has_word "/dev/$_csd_dev" "$_csd_ttys"; then
				printf '%s' "$_csd_dev"
				return 0
			fi
		done
		case "$_csd_ppid" in
		''|*[!0-9]*|0|1) return 0 ;;
		esac
		_csd_pid="$_csd_ppid"
		_csd_n=$((_csd_n + 1))
	done
	return 0
}

# The session's own login cannot go now (runit stops a service the moment its link goes):
# named with what to remove, and the uninstall ends partial. <what to remove>
console_session_kept() {
	warn "the login on $_cu_own stays (removing it would end this session) — remove $1 after you log out."
	UNINSTALL_KEPT=1
	return 0
}

# A login set up outside Machman stays on: the uninstall undoes only what a run did. <dev>
console_kept_outside() {
	note "$1 keeps its login (set up outside Machman)."
	return 0
}

# init rereads <file> now — unless this session runs on one of the consoles, whose login
# that would end: then the change waits for the next boot, said so.
console_uninstall_reload() {
	if [ -n "$_cu_own" ]; then
		console_reload_deferred "$1" "$_cu_own"
	else
		kill -HUP 1 2>/dev/null || true
	fi
	return 0
}

# Uninstalled from a console login Machman set up (the obvious place on a headless guest),
# that login is disabled but keeps running until the next boot: stopping it would end the
# session — and the run — halfway, before the report says it is gone.
console_uninstall() {
	_cu_own="$(console_session_device)"
	case "$GETTY_MECH" in
	systemd)
		# Only what a run of this script enabled (the state lists it), while it still is: a
		# runtime or generated unit (the getty-generator's hvc0) is systemd's own.
		for _cu_dev in $ST_CONSOLE_LOGINS; do
			[ "$(systemctl is-enabled "serial-getty@$_cu_dev.service" 2>/dev/null \
				| head -n 1)" = enabled ] || continue
			if [ "$_cu_dev" = "$_cu_own" ]; then
				run "disabling the login on $_cu_dev" \
					systemctl disable "serial-getty@$_cu_dev.service" || true
				note "$_cu_dev keeps its login until the next boot — stopping it now would end this session."
			else
				run "disabling the login on $_cu_dev" \
					systemctl disable --now "serial-getty@$_cu_dev.service" || true
			fi
		done
		for _cu_dev in $CONSOLE_DEVICES; do
			if ! has_word "$_cu_dev" "$ST_CONSOLE_LOGINS" && getty_unit_enabled "$_cu_dev"
			then
				console_kept_outside "$_cu_dev"
			fi
		done
		;;
	inittab)
		strip_block /etc/inittab || uninstall_kept
		restore_superseded /etc/inittab || uninstall_kept
		console_uninstall_reload /etc/inittab
		;;
	ttys)
		strip_block /etc/ttys || uninstall_kept
		restore_superseded /etc/ttys || uninstall_kept
		console_uninstall_reload /etc/ttys
		# Deliberate keep, disclosed when a run listed it: un-listing virtio_console would
		# take away the console devices — possibly the very one this uninstall is read on.
		if [ "$OS_FAMILY" = freebsd ] && kld_list_ours virtio_console; then
			note "kld_list keeps virtio_console (the console devices stay) — 'sysrc kld_list-=virtio_console' reverts it."
		fi
		;;
	runit)
		# Only what a run added: the Machman-named services, an older Machman's own
		# agetty-<dev>, and the links to Void's own services the state says it made. A
		# service whose run is a link (Void's) is never removed.
		for _cu_sv in "$RUNIT_SV_DIR"/machman-agetty-* "$RUNIT_SV_DIR"/agetty-*; do
			[ -d "$_cu_sv" ] || continue
			_cu_name="$(basename "$_cu_sv")"
			case "$_cu_name" in
			machman-agetty-*)
				_cu_dev="${_cu_name#machman-agetty-}"
				console_runit_own "$_cu_dev" || continue
				;;
			*)
				_cu_dev="${_cu_name#agetty-}"
				console_runit_legacy "$_cu_dev" || continue
				;;
			esac
			if [ "$_cu_dev" = "$_cu_own" ]; then
				console_session_kept "$RUNIT_SERVICE_DIR/$_cu_name and $_cu_sv"
				continue
			fi
			rm -f "$RUNIT_SERVICE_DIR/$_cu_name"
			rm -rf "$_cu_sv"
		done
		for _cu_dev in $ST_CONSOLE_LOGINS; do
			_cu_link="$RUNIT_SERVICE_DIR/agetty-$_cu_dev"
			if [ "$(readlink "$_cu_link" 2>/dev/null)" = "$RUNIT_SV_DIR/agetty-$_cu_dev" ]
			then
				if [ "$_cu_dev" = "$_cu_own" ]; then
					console_session_kept "$_cu_link"
				else
					rm -f "$_cu_link"
				fi
			fi
		done
		for _cu_dev in $CONSOLE_DEVICES; do
			if [ "$(console_ownership "$_cu_dev")" = foreign ]; then
				console_kept_outside "$_cu_dev"
			fi
		done
		if console_runit_damaged; then
			warn "$(console_runit_damage)."
			UNINSTALL_KEPT=1
		fi
		;;
	launchd)
		# A loaded job outlives its plist: the session's own login runs until the next boot.
		for _cu_plist in "$LAUNCHD_DIR/$LAUNCHD_GETTY_PREFIX".*.plist; do
			[ -e "$_cu_plist" ] || continue
			if [ -n "$_cu_own" ] && grep -qF "<string>$_cu_own</string>" "$_cu_plist"; then
				note "$_cu_own keeps its login until the next boot — stopping it now would end this session."
			else
				launchctl bootout "system/$(basename "$_cu_plist" .plist)" 2>/dev/null || true
			fi
			rm -f "$_cu_plist"
		done
		;;
	esac
	return 0
}
