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
	freebsd-rc|netbsd-rc) GETTY_MECH=ttys ;;
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
		reason_console="OpenBSD has no virtio-console driver"
		return 0
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
	# Logins an earlier run set up on consoles this run leaves alone stay managed (their
	# lines stay too), so the state keeps listing them.
	for _cdc_dev in $ST_CONSOLE_LOGINS; do
		if ! has_word "$_cdc_dev" "$CONSOLE_SELECTED" \
			&& ! has_word "$_cdc_dev" "$CONSOLE_MANAGED" && getty_persistent_on "$_cdc_dev"
		then
			CONSOLE_MANAGED="${CONSOLE_MANAGED:+$CONSOLE_MANAGED }$_cdc_dev"
		fi
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

# sysvinit's id for a device's line: 1-4 characters, one per DEVICE, so a re-run selecting
# another set never renames a line init is running. hvc<N> → hv<N>, anything else M and its
# last three letters or digits; both stay clear of the distros' own T0/T1 serial entries.
# (Older runs keyed the id by selection index, M<n>: a line restaged for its device
# replaces such a line by device, never by id.)
console_inittab_id() {
	case "$1" in
	hvc[0-9]|hvc[0-9][0-9]) printf 'hv%s' "${1#hvc}" ;;
	*) printf 'M%s' "$(printf '%s' "$1" | tr -cd 'A-Za-z0-9' | sed 's/.*\(...\)$/\1/')" ;;
	esac
}

# console_stage <dev> <line> — one line for the marker block console_flush_lines rebuilds.
console_stage() {
	CONSOLE_STAGE="${CONSOLE_STAGE:+$CONSOLE_STAGE
}$2"
	CONSOLE_STAGED_DEVS="${CONSOLE_STAGED_DEVS:+$CONSOLE_STAGED_DEVS }$1"
	return 0
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
		_cai_line="$(console_inittab_id "$1"):2345:respawn:$(command -v agetty) -L $1 115200 vt100"
	else
		_cai_line="$1::respawn:/sbin/getty 38400 $1"
	fi
	console_stage "$1" "$_cai_line"
	return 0
}

# runit services. Void ships agetty-<dev> for some devices (hvc0, ttyS0, tty1…), each a run
# LINK into the agetty-generic script every getty shares: those are enabled by a link and
# never written. Other devices get machman-agetty-<dev>, a run script of Machman's own.

# The Machman-named service for <dev>, its run carrying this VM's marker.
console_runit_own() {
	regular_file "$RUNIT_SV_DIR/machman-agetty-$1/run" \
		&& grep -qF "$MARKER" "$RUNIT_SV_DIR/machman-agetty-$1/run" 2>/dev/null
}

# An older Machman's own agetty-<dev>: a run FILE (Void's are links) it wrote for <dev>.
console_runit_legacy() {
	regular_file "$RUNIT_SV_DIR/agetty-$1/run" \
		&& grep -qF "$MARKER" "$RUNIT_SV_DIR/agetty-$1/run" 2>/dev/null \
		&& grep -qF "exec agetty $1 " "$RUNIT_SV_DIR/agetty-$1/run" 2>/dev/null
}

# An older Machman wrote through a stock service's run link: the shared script carries a
# Machman marker (this VM's, or a cloned disk's source VM's), and every agetty service runs
# it. Void's package restores it.
console_runit_damaged() {
	regular_file "$RUNIT_SV_DIR/agetty-generic/run" || return 1
	grep -qxF "# $MARKER" "$RUNIT_SV_DIR/agetty-generic/run" 2>/dev/null \
		|| grep -q '^# machman-[0-9a-f]\{12\}$' "$RUNIT_SV_DIR/agetty-generic/run" 2>/dev/null
}

# What console_runit_damaged found, said once by the run and once by the uninstall.
console_runit_damage() {
	printf '%s (%s) — %s' "an older Machman overwrote Void's shared getty script" \
		"$RUNIT_SV_DIR/agetty-generic/run" "restore it with 'xbps-install -f runit-void'"
}

# console_runit_link <dev> <service dir> — enabled by a link in the service dir.
console_runit_link() {
	_crl_link="$RUNIT_SERVICE_DIR/$(basename "$2")"
	[ -e "$_crl_link" ] && return 0
	# A dangling link (its service gone) enables nothing: it makes way.
	[ -L "$_crl_link" ] && rm -f "$_crl_link"
	if run "enabling a login on $1" ln -s "$2" "$RUNIT_SERVICE_DIR/"; then
		ok "login enabled on $1"
	else
		step_failed console "could not link $(basename "$2") into $RUNIT_SERVICE_DIR" \
			"Link it yourself: ln -s $2 $RUNIT_SERVICE_DIR/"
	fi
	return 0
}

# Idempotent: what is already in place stays, and finding nothing to do says nothing.
console_act_runit() {
	_car_stock="$RUNIT_SV_DIR/agetty-$1"
	_car_own="$RUNIT_SV_DIR/machman-agetty-$1"
	if [ "$DRY_RUN" -eq 1 ]; then
		if [ -d "$_car_stock" ] && ! console_runit_legacy "$1"; then
			acting "would link $_car_stock into $RUNIT_SERVICE_DIR"
		else
			acting "would create $_car_own and link it into $RUNIT_SERVICE_DIR"
		fi
		return 0
	fi
	if console_runit_legacy "$1"; then
		# Retired for the Machman-named service: its name is Void's to ship.
		rm -f "$RUNIT_SERVICE_DIR/agetty-$1"
		rm -rf "$_car_stock"
	fi
	if [ -d "$_car_stock" ]; then
		console_runit_link "$1" "$_car_stock"
		return 0
	fi
	if ! have agetty; then
		step_failed console "agetty is missing — no login service for $1" \
			"Install util-linux, then re-run."
		return 0
	fi
	if ! mkdir -p "$_car_own" 2>/dev/null; then
		step_failed console "could not create $_car_own — no login on $1" \
			"Create it yourself, then re-run."
		return 0
	fi
	_car_tmp="$(mktemp)" || {
		step_failed console "could not write $_car_own/run — no login on $1" \
			"Make room for a temporary file, then re-run."
		return 0
	}
	printf '#!/bin/sh\n# %s\nexec agetty -L %s 115200 vt100\n' "$MARKER" "$1" > "$_car_tmp"
	if ! regular_file "$_car_own/run" || ! cmp -s "$_car_tmp" "$_car_own/run"; then
		if ! write_file -m 755 "$_car_own/run" < "$_car_tmp"; then
			rm -f "$_car_tmp"
			step_failed console "could not write $_car_own/run: $R_ERROR" \
				"Fix that, then re-run."
			return 0
		fi
	fi
	rm -f "$_car_tmp"
	console_runit_link "$1" "$_car_own"
	return 0
}

# /etc/ttys, in each BSD's own getty format.
console_act_ttys() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add a getty line for $1 to /etc/ttys"
		return 0
	fi
	if [ "$OS_FAMILY" = netbsd ]; then
		console_stage "$1" "$(printf '%s "/usr/libexec/getty default" vt100 on secure' "$1")"
	else
		console_stage "$1" \
			"$(printf '%s "/usr/libexec/getty 3wire" vt100 onifexists secure' "$1")"
	fi
	return 0
}

console_act_launchd() {
	if [ ! -e "/dev/$1" ]; then
		step_failed console "/dev/$1 is not present in this guest — skipped" \
			"Boot with the console attached, then re-run."
		return 0
	fi
	# Keyed by the device: an older run's label was the console's place in its selection,
	# which another run could give a different device (and overwrite a loaded plist).
	_cal_label="$LAUNCHD_GETTY_PREFIX.$1"
	_cal_plist="$LAUNCHD_DIR/$_cal_label.plist"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would install $_cal_plist for $1"
		return 0
	fi
	for _cal_old in "$LAUNCHD_DIR/$LAUNCHD_GETTY_PREFIX".*.plist; do
		[ -f "$_cal_old" ] && [ "$_cal_old" != "$_cal_plist" ] || continue
		grep -qF "<string>$1</string>" "$_cal_old" 2>/dev/null || continue
		launchctl bootout "system/$(basename "$_cal_old" .plist)" >/dev/null 2>&1 || true
		rm -f "$_cal_old"
	done
	_cal_tmp="$(mktemp)" || {
		step_failed console "could not write $_cal_plist — no login on $1" \
			"Make room for a temporary file, then re-run."
		return 0
	}
	cat > "$_cal_tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$_cal_label</string>
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
	if ! write_file -m 644 -o root:wheel "$_cal_plist" < "$_cal_tmp"; then
		rm -f "$_cal_tmp"
		step_failed console "could not write $_cal_plist: $R_ERROR" \
			"Fix that, then re-run."
		return 0
	fi
	rm -f "$_cal_tmp"
	launchctl bootout "system/$_cal_label" >/dev/null 2>&1 || true
	run "starting the login on $1" launchctl bootstrap system "$_cal_plist" || true
	ok "login installed on $1"
	return 0
}

# The marker block's lines in <file> now; with "keep", only those for devices this run
# staged nothing for (unselected, or skipped as absent) — staged lines replace the rest.
console_block_lines() { # <file> [keep]
	[ -f "$1" ] || return 0
	_cbl_res=""
	if [ "${2:-}" = keep ]; then
		for _cbl_dev in $CONSOLE_STAGED_DEVS; do
			if [ "$GETTY_MECH" = inittab ]; then
				_cbl_re="$(console_inittab_re "$_cbl_dev")"
			else
				_cbl_re="^$(console_dev_esc "$_cbl_dev")[[:space:]]"
			fi
			_cbl_res="${_cbl_res:+$_cbl_res
}$_cbl_re"
		done
	fi
	# The patterns travel through ENVIRON: awk -v would unescape the dots' backslashes.
	_CB_RES="$_cbl_res" awk -v m="$MARKER" '
		BEGIN { n = split(ENVIRON["_CB_RES"], re, "\n") }
		$0 == "# BEGIN " m { inb = 1; next }
		$0 == "# END " m { inb = 0; next }
		inb {
			for (i = 1; i <= n; i++) if ($0 ~ re[i]) next
			print
		}' "$1"
}

# Marker-scoped batch edit: the inittab/ttys lines this run staged land between BEGIN/END
# markers in one block rewrite (idempotent re-runs, exact uninstall), beside the block's
# lines for the consoles it left alone. 0 when the file changed; 1 when it did not need to,
# or could not (said so).
console_flush_lines() {
	[ -n "$CONSOLE_STAGE" ] || return 1
	_cfl_body="$(console_block_lines "$1" keep; printf '%s\n' "$CONSOLE_STAGE")"
	_cfl_now="$(console_block_lines "$1")"
	CONSOLE_STAGE=""
	CONSOLE_STAGED_DEVS=""
	[ "$_cfl_body" != "$_cfl_now" ] || return 1
	if ! put_block "$1" "$MARKER" "$_cfl_body"; then
		step_failed console "could not update $1: $R_ERROR" \
			"Add the getty lines yourself, then re-run."
		return 1
	fi
	return 0
}

# The install arm for one device (adopt falls through here after superseding).
console_install_one() {
	# A respawning getty on an absent device is a churn loop (systemd's unit binds the
	# device and waits; launchd checks itself) — skip what is not there and say so.
	case "$GETTY_MECH" in
	inittab|runit|ttys)
		if [ ! -e "/dev/$1" ] && [ "$DRY_RUN" -eq 0 ]; then
			step_failed console "/dev/$1 is not present in this guest — skipped" \
				"Boot with the console attached, then re-run."
			return 0
		fi
		;;
	esac
	case "$GETTY_MECH" in
	systemd) console_act_systemd "$1" ;;
	inittab) console_act_inittab "$1" ;;
	runit) console_act_runit "$1" ;;
	ttys) console_act_ttys "$1" ;;
	launchd) console_act_launchd "$1" ;;
	esac
	return 0
}

console_act() {
	if [ "$GETTY_MECH" = runit ] && console_runit_damaged; then
		step_failed console "$(console_runit_damage)" \
			"Every agetty service runs that script until it is restored."
	fi
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
	# Older versions staged into these files; one a killed run left behind goes.
	rm -f /etc/inittab.machman-add /etc/ttys.machman-add 2>/dev/null || true
	CONSOLE_STAGE=""
	CONSOLE_STAGED_DEVS=""
	_ca_flush=0
	for _ca_dev in $CONSOLE_SELECTED; do
		case "$(console_action_of "$_ca_dev")" in
		auto)
			ok "$_ca_dev: automatic login (systemd) — nothing to do"
			;;
		verify)
			if getty_persistent_on "$_ca_dev"; then
				# A login in a shared file is staged again, so the block it is rebuilt
				# with keeps it (in this version's format); a runit service an older
				# Machman wrote moves to its Machman-named one.
				if [ "$DRY_RUN" -eq 0 ]; then
					case "$GETTY_MECH" in
					inittab|ttys) console_install_one "$_ca_dev"; _ca_flush=1 ;;
					runit) console_install_one "$_ca_dev" ;;
					esac
				fi
				ok "login on $_ca_dev verified"
			else
				# Drifted since detection (or the state file lied): reinstall.
				console_install_one "$_ca_dev"
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
				_ca_ok=0
				case "$GETTY_MECH" in
				inittab)
					supersede_lines /etc/inittab "$(console_inittab_re "$_ca_dev")" \
						|| _ca_ok=1 ;;
				ttys)
					supersede_lines /etc/ttys \
						"^$(console_dev_esc "$_ca_dev")[[:space:]]" || _ca_ok=1 ;;
				esac
				if [ "$_ca_ok" -ne 0 ]; then
					# A second getty on the same port would fight the first one.
					step_failed console "could not adopt $_ca_dev: $R_ERROR" \
						"Comment its line out yourself, then re-run."
					continue
				fi
				ok "adopted $_ca_dev — the original line is tagged and restorable"
			fi
			console_install_one "$_ca_dev"
			_ca_flush=1
			;;
		install)
			console_install_one "$_ca_dev"
			_ca_flush=1
			;;
		esac
	done
	if [ "$DRY_RUN" -eq 0 ] && [ "$_ca_flush" -eq 1 ]; then
		case "$GETTY_MECH" in
		inittab)
			if console_flush_lines /etc/inittab; then
				run "reloading init" kill -HUP 1 || true
				ok "logins land in /etc/inittab"
			fi
			;;
		ttys)
			if console_flush_lines /etc/ttys; then
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

# init rereads <file> now — unless this session runs on one of the consoles, whose login
# that would end: then the change waits for the next boot, said so.
console_uninstall_reload() {
	if [ -n "$_cu_own" ]; then
		note "$1 changes take effect at the next boot — reloading init now would end this session on $_cu_own."
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
		# Only what a run of this script would have enabled: the explicit units.
		for _cu_dev in $CONSOLE_DEVICES; do
			systemctl is-enabled "serial-getty@$_cu_dev.service" >/dev/null 2>&1 || continue
			if [ "$_cu_dev" = "$_cu_own" ]; then
				run "disabling the login on $_cu_dev" \
					systemctl disable "serial-getty@$_cu_dev.service" || true
				note "$_cu_dev keeps its login until the next boot — stopping it now would end this session."
			else
				run "disabling the login on $_cu_dev" \
					systemctl disable --now "serial-getty@$_cu_dev.service" || true
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
		# Deliberate keep, disclosed: un-listing virtio_console would take away the
		# console devices — possibly the very one this uninstall is being read on.
		if [ "$OS_FAMILY" = freebsd ] \
			&& sysrc -n kld_list 2>/dev/null | grep -q virtio_console; then
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
