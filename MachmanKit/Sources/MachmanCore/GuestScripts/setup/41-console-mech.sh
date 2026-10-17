# === machman-setup: 41-console-mech ===
# Console logins, the act: each init's mechanism, the shared-file flush and the driver that
# applies every console's verb. 40-console holds the model, the decision, the report and the
# uninstall.

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
		&& has_our_marker "$RUNIT_SV_DIR/machman-agetty-$1/run"
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
	if [ "$OS_FAMILY" = netbsd ] || [ "$OS_FAMILY" = openbsd ]; then
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

# The ERE of <dev>'s line in the shared getty file: inittab's getty entry, a ttys line.
console_line_re() {
	if [ "$GETTY_MECH" = inittab ]; then
		console_inittab_re "$1"
	else
		printf '^%s[[:space:]]' "$(console_dev_esc "$1")"
	fi
}

# The marker block's lines in <file> now; with "keep", only those for devices this run
# staged nothing for (unselected, or skipped as absent) — staged lines replace the rest.
console_block_lines() { # <file> [keep]
	[ -f "$1" ] || return 0
	_cbl_res=""
	if [ "${2:-}" = keep ]; then
		for _cbl_dev in $CONSOLE_STAGED_DEVS; do
			_cbl_res="${_cbl_res:+$_cbl_res
}$(console_line_re "$_cbl_dev")"
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

# The staged consoles whose line in <file>'s block the flush changes — a new line, or one in
# another format (an adopted console's original went out of the file): init's reload
# restarts their gettys.
console_changed_devs() { # <file>
	_ccd_i=0
	for _ccd_dev in $CONSOLE_STAGED_DEVS; do
		_ccd_i=$((_ccd_i + 1))
		_ccd_new="$(printf '%s\n' "$CONSOLE_STAGE" | sed -n "${_ccd_i}p")"
		_ccd_old="$(console_block_lines "$1" \
			| _CB_RE="$(console_line_re "$_ccd_dev")" awk '$0 ~ ENVIRON["_CB_RE"]')"
		[ "$_ccd_old" = "$_ccd_new" ] || printf '%s ' "$_ccd_dev"
	done
	return 0
}

# init rereads <file> later: now it would end this session on <dev>.
console_reload_deferred() { # <file> <dev>
	note "$1 changes take effect at the next boot — reloading init now would end this session on $2."
}

# The staged lines land in <file> and init rereads it — unless this run's session sits on a
# console whose line changed: the reload would end that login (S44), so it waits for the
# next boot, said so.
console_flush_and_reload() { # <file>
	_cfr_changed="$(console_changed_devs "$1")"
	console_flush_lines "$1" || return 0
	_cfr_own="$(console_session_device)"
	if [ -n "$_cfr_own" ] && has_word "$_cfr_own" "$_cfr_changed"; then
		console_reload_deferred "$1" "$_cfr_own"
	else
		run "reloading init" kill -HUP 1 || true
	fi
	ok "logins land in $1"
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
			kld_list_add virtio_console || true
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
		keep)
			# Checked like a login of ours, but never taken over: gone since detection, it
			# is set up by a re-run, not here.
			if getty_persistent_on "$_ca_dev"; then
				ok "login on $_ca_dev verified (set up outside Machman)"
			else
				note "$_ca_dev has no login now (it was set up outside Machman) — re-run to set one up."
			fi
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
		inittab) console_flush_and_reload /etc/inittab ;;
		ttys) console_flush_and_reload /etc/ttys ;;
		esac
	fi
	return 0
}
