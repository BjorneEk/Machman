# === machman-setup: 30-state ===
# Persistent guest-side state: what this script configured, and which version wrote it —
# so a re-run can offer reconfiguration instead of starting blind, and a newer script can
# repair older layouts. One flat key=value file, written after the act phase.

# 2: the sshfs automounts' names are TAB-separated (version 1 joined them with spaces).
STATE_VERSION=2
STATE_DIR=""
STATE_FILE=""
HAD_STATE=0
# What the state file taught us (empty until read).
ST_SCRIPT_VERSION=""
ST_CONFIGURED=""           # space-separated feature ids
ST_CONSOLE_LOGINS=""
ST_KERNEL_CONSOLE=""
ST_KERNEL_CONSOLE_METHOD=""
ST_SSH_USER=""
ST_AUTOMOUNT_SSHFS=""      # TAB-separated mount names (they carry spaces)
ST_MOUNTPOINT=""           # where sshfs automounts land — report-only reconstructs with it
ST_KLD_ADDED=""            # FreeBSD kld_list entries a run added (KLD_ADDED; none before v7)
ST_LAST_STATUS=""          # ok|partial from the last real run — --report-only keeps it
ST_LAST_NOTE=""            # …with its one-sentence note, failed steps, and the error and
ST_LAST_FAILED_STEPS=""    # note lines ("step: message", newline-separated) that explain
ST_ERR_LINES=""            # it
ST_NOTE_LINES=""
CLONED=0                   # the state was another VM's: this guest is a copy of it

state_paths() {
	case "$OS_FAMILY" in
	darwin|freebsd|openbsd|netbsd) STATE_DIR="/var/db/machman" ;;
	*) STATE_DIR="/var/lib/machman" ;;
	esac
	STATE_FILE="$STATE_DIR/state.env"
	return 0
}

# Parsed, never sourced — same reasoning as /etc/os-release. Values are written sh-quoted
# (sh_quote): one outer pair of quotes goes, and each '\'' turns back into '. A value an
# older script wrote raw between quotes reads the same way.
state_get() {
	sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1 \
		| sed "s/^'//; s/'\$//; s/'\\\\''/'/g"
}

# state_line <key> <value> — one KEY='value' line, the value sh-quoted.
state_line() {
	printf '%s=%s\n' "$1" "$(sh_quote "$2")"
}

# state_lines <prefix> <lines> — <prefix>1, <prefix>2, … one per non-empty line.
state_lines() {
	_sls_i=1
	printf '%s\n' "$2" | while IFS= read -r _sls_line; do
		[ -n "$_sls_line" ] || continue
		state_line "$1$_sls_i" "$_sls_line"
		_sls_i=$((_sls_i + 1))
	done
}

# state_list <prefix> — the values of <prefix><n> keys, unquoted, in file order.
state_list() {
	sed -n "/^$1[0-9][0-9]*=/{s/^$1[0-9][0-9]*=//;s/^'//;s/'\$//;s/'\\\\''/'/g;p;}" \
		"$STATE_FILE" 2>/dev/null
}

read_state() {
	state_paths
	[ -r "$STATE_FILE" ] || return 0
	# A cloned guest carries the source VM's state; its records describe artifacts
	# tagged with the source's marker, which the ownership probes treat as foreign.
	# Start fresh instead of trusting them. (Pre-marker v3 states pass as ours.) What
	# carries no marker is known only from the record, so that much stays, and the copy's
	# first state carries it on: the systemd units and runit links its source's runs
	# enabled, and the kld_list entries they added.
	_rs_marker="$(state_get MARKER)"
	if [ -n "$_rs_marker" ] && [ "$_rs_marker" != "$MARKER" ]; then
		note "this guest looks cloned from another Machman VM — treating it as new"
		CLONED=1
		case "$INIT" in
		systemd|runit) ST_CONSOLE_LOGINS="$(state_get CONSOLE_LOGINS)" ;;
		esac
		ST_KLD_ADDED="$(state_get KLD_ADDED)"
		return 0
	fi
	HAD_STATE=1
	ST_SCRIPT_VERSION="$(state_get SCRIPT_VERSION)"
	ST_CONFIGURED="$(state_get CONFIGURED)"
	ST_CONSOLE_LOGINS="$(state_get CONSOLE_LOGINS)"
	ST_KERNEL_CONSOLE="$(state_get KERNEL_CONSOLE)"
	ST_KERNEL_CONSOLE_METHOD="$(state_get KERNEL_CONSOLE_METHOD)"
	ST_SSH_USER="$(state_get SSH_USER)"
	ST_AUTOMOUNT_SSHFS="$(state_get AUTOMOUNT_SSHFS)"
	# Version 1 joined the names with spaces: a name with one never survived it anyway.
	case "$(state_get STATE_VERSION)" in
	''|1) ST_AUTOMOUNT_SSHFS="$(printf '%s' "$ST_AUTOMOUNT_SSHFS" | tr ' ' '\t')" ;;
	esac
	ST_MOUNTPOINT="$(state_get MOUNTPOINT)"
	ST_KLD_ADDED="$(state_get KLD_ADDED)"
	ST_LAST_STATUS="$(state_get LAST_STATUS)"
	ST_LAST_NOTE="$(state_get LAST_NOTE)"
	ST_LAST_FAILED_STEPS="$(state_get LAST_FAILED_STEPS)"
	ST_ERR_LINES="$(state_list ERROR_)"
	ST_NOTE_LINES="$(state_list NOTE_)"
	verbose state "v${ST_SCRIPT_VERSION:-?} configured=[${ST_CONFIGURED:-}]"
	# Repairs for older layouts land here as the versions accumulate. v3 is the first
	# version writing state at all (v2 left only marker-tagged artifacts), so there is
	# nothing to migrate yet — v2 artifacts are simply re-detected feature by feature.
	return 0
}

state_was_configured() {
	has_word "$1" "$ST_CONFIGURED"
}

# A --report-only run describes the last real run (write_report takes its status from the
# state): that run's note, failed steps, and error and note lines become this report's.
state_replay_outcome() {
	FAILED_STEPS="$ST_LAST_FAILED_STEPS"
	R_LAST_FAILURE="$ST_LAST_NOTE"
	ERR_LINES="$ST_ERR_LINES"
	NOTE_LINES="$ST_NOTE_LINES"
	return 0
}

# write_state <configured feature ids, space-separated>
write_state() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	mkdir -p "$STATE_DIR" 2>/dev/null || {
		step_failed state "could not create $STATE_DIR — re-runs will not remember choices" \
			"Create it yourself and re-run."
		return 0
	}
	# Composed in a root-only temp file, then written whole: never through a link.
	_ws_tmp="$(mktemp)" || {
		step_failed state "could not write $STATE_FILE — re-runs will not remember choices" \
			"Make room for a temporary file, then re-run."
		return 0
	}
	{
		printf 'STATE_VERSION=%s\n' "$STATE_VERSION"
		printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
		state_line MARKER "$MARKER"
		state_line CONFIGURED "$1"
		if [ -n "$FAILED_STEPS" ]; then
			state_line LAST_STATUS partial
		else
			state_line LAST_STATUS ok
		fi
		# What explains that status, for --report-only (the boot-time refresh) to report.
		[ -n "$R_LAST_FAILURE" ] && state_line LAST_NOTE "$R_LAST_FAILURE"
		[ -n "$FAILED_STEPS" ] && state_line LAST_FAILED_STEPS "$FAILED_STEPS"
		state_lines ERROR_ "$ERR_LINES"
		state_lines NOTE_ "$NOTE_LINES"
		# Each feature's record is this run's when the run acted on it, else the last
		# run's: what a feature configured stays configured whatever a later run selects,
		# and uninstall and --report-only work from the record (grubby's arguments, the
		# key's user, the automounts' names).
		if feature_selected console; then
			_ws_logins="$CONSOLE_MANAGED"
		else
			_ws_logins="$ST_CONSOLE_LOGINS"
		fi
		# The kernel console: what this run set, else what an earlier run set (also when
		# this one found it in place and changed nothing).
		if [ -n "$KC_DEVICE_DONE" ]; then
			_ws_kc="$KC_DEVICE_DONE"
			_ws_kcm="$KC_METHOD_DONE"
		else
			_ws_kc="$ST_KERNEL_CONSOLE"
			_ws_kcm="$ST_KERNEL_CONSOLE_METHOD"
		fi
		if feature_selected ssh; then
			_ws_user="$U"
		else
			_ws_user="${ST_SSH_USER:-$U}"
		fi
		[ -n "$_ws_logins" ] && state_line CONSOLE_LOGINS "$_ws_logins"
		[ -n "$_ws_kc" ] && state_line KERNEL_CONSOLE "$_ws_kc"
		[ -n "$_ws_kcm" ] && state_line KERNEL_CONSOLE_METHOD "$_ws_kcm"
		[ -n "$_ws_user" ] && state_line SSH_USER "$_ws_user"
		# A run that leaves the sshfs automounts alone (or selects them and chooses none)
		# keeps their record: their fstab lines or boot script stay.
		if feature_selected sshfsauto && [ -n "$SSHFSAUTO_SELECTED" ]; then
			_ws_auto="$SSHFSAUTO_DONE"
			_ws_root="$MOUNTPOINT"
		else
			_ws_auto="$ST_AUTOMOUNT_SSHFS"
			_ws_root="${ST_MOUNTPOINT:-$MOUNTPOINT}"
		fi
		[ -n "$_ws_auto" ] && state_line AUTOMOUNT_SSHFS "$_ws_auto"
		[ -n "$_ws_auto" ] && state_line MOUNTPOINT "$_ws_root"
		# The kld_list entries any run added: one a later run finds in place stays its.
		_ws_kld="$ST_KLD_ADDED"
		for _ws_m in $KLD_ADDED; do
			has_word "$_ws_m" "$_ws_kld" || _ws_kld="${_ws_kld:+$_ws_kld }$_ws_m"
		done
		[ -n "$_ws_kld" ] && state_line KLD_ADDED "$_ws_kld"
		:
	} > "$_ws_tmp"
	if ! write_file -m 600 "$STATE_FILE" < "$_ws_tmp"; then
		rm -f "$_ws_tmp"
		step_failed state "$R_ERROR — re-runs will not remember choices" \
			"Fix that, then re-run."
		return 0
	fi
	rm -f "$_ws_tmp"
	verbose state "wrote $STATE_FILE"
	return 0
}

# ---------------------------------------------------------------- FreeBSD kld_list ----

# A kld_list entry carries no marker, so a run records the ones it adds, and the uninstall
# names only those (an entry the admin listed is theirs). A state without the record, as
# every one before v7 is, added none.
KLD_ADDED=""               # the entries this run added, space-separated

# kld_list_add <module> — loaded at every boot from now on, recorded as this run's.
kld_list_add() {
	run "keeping $1 across reboots" sysrc "kld_list+=$1" || return 1
	KLD_ADDED="${KLD_ADDED:+$KLD_ADDED }$1"
	return 0
}

# Is <module> in kld_list because a run of this script put it there?
kld_list_ours() {
	has_word "$1" "$ST_KLD_ADDED $KLD_ADDED" || return 1
	sysrc -n kld_list 2>/dev/null | grep -q "$1"
}

remove_state() {
	rm -f "$STATE_FILE" 2>/dev/null || true
	rmdir "$STATE_DIR" 2>/dev/null || true
	return 0
}

# -------------------------------------------------------------- a copy's own identity ----

# A copy's disk keeps its source's machine id, which systemd-networkd derives its DHCP
# client id from, and dhcpcd's own DUID (and the secret behind its stable IPv6 addresses):
# the copy would lease the source's address. Their files, and dbus's copy of the machine id
# where the distro keeps one (Debian does). dhcpcd 9 and later keep theirs in its database
# dir (Linux's or the BSDs'), older ones beside its config. It keeps its source's SSH host
# keys too, so a client that mixed the two VMs up (an address, a client id) would log into
# the source without a warning.
MACHINE_ID_FILE=/etc/machine-id
DBUS_MACHINE_ID_FILE=/var/lib/dbus/machine-id
DHCPCD_ID_FILES="/var/lib/dhcpcd/duid /var/lib/dhcpcd/secret /var/db/dhcpcd/duid
/var/db/dhcpcd/secret /etc/dhcpcd.duid /etc/dhcpcd.secret"
SSH_HOST_KEY_DIR=/etc/ssh
IDENTITY_RENEWED=0         # the machine id or DHCP client id: the address follows at boot

# What a copy renews: any of "machine-id", "dhcpcd" and "ssh-keys", or nothing (no copy,
# nothing to renew); "ssh-key-links" when host keys it keeps are links.
identity_to_renew() {
	[ "$CLONED" -eq 1 ] || return 0
	_itr=""
	if linux_guest && regular_file "$MACHINE_ID_FILE" && [ -s "$MACHINE_ID_FILE" ]; then
		_itr=machine-id
	fi
	for _itr_f in $DHCPCD_ID_FILES; do
		if regular_file "$_itr_f"; then
			_itr="${_itr:+$_itr }dhcpcd"
			break
		fi
	done
	[ -n "$(identity_host_keys)" ] && _itr="${_itr:+$_itr }ssh-keys"
	[ -n "$(identity_host_keys -l)" ] && _itr="${_itr:+$_itr }ssh-key-links"
	printf '%s' "$_itr"
}

# The SSH host keys there are (ssh_host_<type>_key), one path per line: the files, or with
# -l the links — someone else's arrangement (NixOS keeps them on /persist, which a copy's
# disk carries too), kept and named.
identity_host_keys() {
	for _ihk in "$SSH_HOST_KEY_DIR"/ssh_host_*_key; do
		if [ "${1:-}" = -l ]; then
			[ -L "$_ihk" ] || continue
		else
			regular_file "$_ihk" || continue
		fi
		printf '%s\n' "$_ihk"
	done
	return 0
}

# A random machine id as systemd writes one: 32 lowercase hex digits, version 4.
identity_new_id() {
	od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | awk '
		length($0) == 32 {
			v = substr("89ab", index("0123456789abcdef", substr($0, 17, 1)) % 4 + 1, 1)
			print substr($0, 1, 12) "4" substr($0, 14, 3) v substr($0, 18)
		}'
}

identity_plan() {
	_ip_renew="$(identity_to_renew)"
	set --
	for _ip_w in $_ip_renew; do
		case "$_ip_w" in
		machine-id) set -- "$@" "machine id" ;;
		dhcpcd) set -- "$@" "DHCP client id" ;;
		ssh-keys) set -- "$@" "SSH host keys" ;;
		esac
	done
	case $# in
	0) return 0 ;;
	1) _ip_what="$1" ;;
	2) _ip_what="$1 and $2" ;;
	*) _ip_what="$1, $2 and $3" ;;
	esac
	case "$_ip_what" in
	SSH*) _ip_what="new $_ip_what" ;;
	*) _ip_what="a new $_ip_what" ;;
	esac
	_ip_what="$_ip_what for this copy"
	case "$_ip_renew" in
	*machine-id*|*dhcpcd*) _ip_what="$_ip_what — its own address from the next boot" ;;
	esac
	plan_line "identity" "$_ip_what"
}

# Written now, taken up at the next boot (networkd and dhcpcd read theirs when they start):
# a whole new id rather than an emptied file, so no init has to fill one in. Edited in place
# (rewrite_file), so each file keeps its owner and mode.
identity_act() {
	_ia_what="$(identity_to_renew)"
	if has_word machine-id "$_ia_what"; then
		R_ERROR=""
		_ia_id="$(identity_new_id)"
		if [ "${#_ia_id}" -eq 32 ] \
			&& rewrite_file "$MACHINE_ID_FILE" printf '%s\n' "$_ia_id"; then
			if regular_file "$DBUS_MACHINE_ID_FILE"; then
				rewrite_file "$DBUS_MACHINE_ID_FILE" printf '%s\n' "$_ia_id" \
					|| warn "$R_ERROR — dbus keeps the source's machine id."
			fi
			IDENTITY_RENEWED=1
			ok "gave this copy a machine id of its own"
		else
			step_failed identity \
				"could not give this copy a machine id of its own${R_ERROR:+: $R_ERROR}" \
				"Write a new one yourself (systemd-machine-id-setup does), then reboot."
		fi
	fi
	if has_word dhcpcd "$_ia_what"; then
		_ia_dropped=0
		for _ia_f in $DHCPCD_ID_FILES; do
			regular_file "$_ia_f" || continue
			if rm -f "$_ia_f"; then
				_ia_dropped=1
			else
				step_failed identity "could not remove $_ia_f" "Remove it yourself, then reboot."
			fi
		done
		if [ "$_ia_dropped" -eq 1 ]; then
			IDENTITY_RENEWED=1
			ok "dropped the source's DHCP client id (dhcpcd makes one at the next boot)"
		fi
	fi
	has_word ssh-keys "$_ia_what" && identity_new_host_keys
	if has_word ssh-key-links "$_ia_what"; then
		for _ia_link in $(identity_host_keys -l); do
			note "$_ia_link is a link, so it stays and this copy serves its source's host key until you replace it."
		done
	fi
	return 0
}

# Each host key is made anew beside the old one and moved over it (one ssh-keygen cannot
# make keeps the old: OpenSSH 9.8 dropped DSA, whose key its sshd no longer serves either),
# then sshd reloads — its listener reads the keys again, running sessions stay — so the
# report this run writes carries the key sshd serves, and the host pins it.
identity_new_host_keys() {
	_inh_done=0
	for _inh_key in $(identity_host_keys); do
		_inh_type="${_inh_key##*/ssh_host_}"
		_inh_type="${_inh_type%_key}"
		rm -f "$_inh_key.new" "$_inh_key.new.pub"
		if ssh-keygen -q -t "$_inh_type" -N '' -f "$_inh_key.new" >/dev/null 2>&1 \
			&& mv -f "$_inh_key.new" "$_inh_key" && mv -f "$_inh_key.new.pub" "$_inh_key.pub"
		then
			if have restorecon; then
				restorecon "$_inh_key" "$_inh_key.pub" >/dev/null 2>&1 || true
			fi
			_inh_done=1
		else
			rm -f "$_inh_key.new" "$_inh_key.new.pub"
			[ "$_inh_type" = dsa ] && continue
			step_failed identity "could not make a new $_inh_type host key for this copy" \
				"Remove $_inh_key and run 'ssh-keygen -A', then reload sshd."
		fi
	done
	[ "$_inh_done" -eq 1 ] || return 0
	ok "gave this copy SSH host keys of its own"
	if [ "$SSHD" = running ] && ! identity_reload_sshd; then
		note "sshd serves them from the next boot."
	fi
	return 0
}

# sshd re-reads its host keys on a reload; launchd's starts per connection, so the next
# one has them.
identity_reload_sshd() {
	case "$INIT" in
	launchd) return 0 ;;
	systemd) run "reloading sshd" systemctl reload "$SSHD_UNIT" ;;
	freebsd-rc) run "reloading sshd" service sshd reload ;;
	openbsd-rc) run "reloading sshd" rcctl reload sshd ;;
	netbsd-rc) run "reloading sshd" /etc/rc.d/sshd reload ;;
	openrc) run "reloading sshd" rc-service sshd reload ;;
	runit) run "reloading sshd" sv hup sshd ;;
	inittab|sysv) run "reloading sshd" service "$SSHD_UNIT" reload ;;
	*) return 1 ;;
	esac
}

# ------------------------------------------------------------------------ mounts.list ----

# kind<TAB>name<TAB>hostpath per line. Consumed by the automount features; missing file
# just means no mounts (older payloads, mount-less VMs). Names carry spaces (the host
# allows them), so every list of names stays newline- or tab-separated — never packed
# into one space-joined word list.
MOUNTS_SSHFS=""            # newline-separated "name<TAB>hostpath"

read_mounts_list() {
	[ -r "$MOUNTS_LIST" ] || return 0
	_rml_tab="$(printf '\t')"
	while IFS="$_rml_tab" read -r _rml_kind _rml_name _rml_path; do
		case "$_rml_kind" in
		''|'#'*) continue ;;
		sshfs)
			if [ -z "$MOUNTS_SSHFS" ]; then
				MOUNTS_SSHFS="$_rml_name$_rml_tab$_rml_path"
			else
				MOUNTS_SSHFS="$MOUNTS_SSHFS
$_rml_name$_rml_tab$_rml_path"
			fi
			;;
		esac
	done < "$MOUNTS_LIST"
	verbose detect "sshfs mounts=[$(printf '%s' "$MOUNTS_SSHFS" \
		| awk -F "$_rml_tab" '{ print $1 }' | tr '\n' ' ')]"
	return 0
}
