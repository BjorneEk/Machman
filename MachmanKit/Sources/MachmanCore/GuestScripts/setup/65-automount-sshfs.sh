# === machman-setup: 65-automount-sshfs ===
# Feature: mount sshfs-carried host folders at boot — and, on guests without a virtiofs
# driver, the Machman share itself. Rides the guest -> host link ('ssh mac' must be
# approved in Machman before any of it connects). systemd guests get on-demand fstab
# automounts (network-safe); others get a marker-tagged boot script, best-effort.

SSHFSAUTO_PLAN=""
SSHFSAUTO_SELECTED=""      # mount names chosen, space-separated ("@share" = the share)
SSHFSAUTO_DONE=""
avail_sshfsauto=0
reason_sshfsauto=""

sshfsauto_detect() {
	return 0
}

sshfsauto_is_configured() {
	sshfsauto_configured
}

sshfsauto_menu_note() {
	_smn_count=0
	[ -n "$MOUNTS_SSHFS" ] \
		&& _smn_count="$(printf '%s\n' "$MOUNTS_SSHFS" | wc -l | tr -d ' ')"
	if sshfsauto_configured; then
		echo "configured — verify"
	elif [ "$_smn_count" -gt 0 ]; then
		echo "mount $_smn_count host folder(s) at boot"
	else
		echo "mount the share at boot over ssh"
	fi
	return 0
}

sshfsauto_menu_default() {
	if state_was_configured sshfsauto; then echo 1; else echo 0; fi
	return 0
}

sshfsauto_configured() {
	[ -n "$ST_AUTOMOUNT_SSHFS" ] \
		|| { grep -q "^# BEGIN $MARKER" /etc/fstab 2>/dev/null \
			&& grep -q "fuse.sshfs" /etc/fstab 2>/dev/null; }
}

# "name<TAB>note" lines (the menus' format); the name half may itself carry spaces, so
# consumers cut at the TAB, never at whitespace.
sshfsauto_items() {
	_si_tab="$(printf '\t')"
	[ "$VIRTIOFS_OK" -eq 0 ] && [ "$OS_FAMILY" != darwin ] \
		&& printf '@share%sthe Machman share (installers + reports)\n' "$_si_tab"
	[ -n "$MOUNTS_SSHFS" ] \
		&& printf '%s\n' "$MOUNTS_SSHFS" | awk -F "$_si_tab" '{ print $1 }'
	return 0
}

sshfsauto_available() {
	avail_sshfsauto=0
	reason_sshfsauto=""
	if [ "$OS_FAMILY" = darwin ]; then
		reason_sshfsauto="macOS needs macFUSE — install it yourself"
		return 0
	fi
	if [ -z "$(sshfsauto_items)" ]; then
		reason_sshfsauto="no sshfs mounts on this VM — set a mount's kind to sshfs in Machman"
		return 0
	fi
	if [ -z "$GATEWAY" ]; then
		reason_sshfsauto="no route to the Mac — the guest needs a default route first"
		return 0
	fi
	avail_sshfsauto=1
	return 0
}

sshfsauto_decide() {
	SSHFSAUTO_SELECTED=""
	_sd_items="$(sshfsauto_items)"
	_sd_tab="$(printf '\t')"
	# Names cut at the item's TAB, never at whitespace: mount names carry spaces, and a
	# word-split name misses sshfsauto_entry's lookup. Selection stays newline-separated.
	_sd_names="$(printf '%s\n' "$_sd_items" | sed '/^$/d' | awk -F "$_sd_tab" '{ print $1 }')"
	_sd_count="$(printf '%s\n' "$_sd_names" | sed '/^$/d' | wc -l | tr -d ' ')"
	if [ "$_sd_count" = 1 ]; then
		SSHFSAUTO_SELECTED="$_sd_names"
	else
		_sd_marks=""
		_sd_i=1
		while [ "$_sd_i" -le "$_sd_count" ]; do
			toggle_mark "$_sd_marks" "$_sd_i"
			_sd_marks="$R_MARKS"
			_sd_i=$((_sd_i + 1))
		done
		menu_multi "Mount which host folders at boot (over sshfs)?" "$_sd_items" "$_sd_marks"
		_sd_old_ifs="$IFS"
		IFS='
'
		# shellcheck disable=SC2086
		set -f
		set -- $_sd_names
		set +f
		IFS="$_sd_old_ifs"
		_sd_i=1
		for _sd_name in "$@"; do
			case ",$R_MARKS," in
			*",$_sd_i,"*)
				SSHFSAUTO_SELECTED="${SSHFSAUTO_SELECTED:+$SSHFSAUTO_SELECTED
}$_sd_name"
				;;
			esac
			_sd_i=$((_sd_i + 1))
		done
	fi
	_sd_disp="$(printf '%s' "${SSHFSAUTO_SELECTED:-none}" | tr '\n' ',' | sed 's/,/, /g')"
	SSHFSAUTO_PLAN="$_sd_disp (as $U, needs guest -> host approval)"
	if [ "$INIT" != systemd ]; then
		SSHFSAUTO_PLAN="$SSHFSAUTO_PLAN, boot-script fallback"
	fi
	return 0
}

sshfsauto_plan() {
	plan_line "sshfs automount" "$SSHFSAUTO_PLAN"
	return 0
}

# fstab escapes spaces as \040; both host paths and mountpoints can carry them.
fstab_escape() {
	printf '%s' "$1" | sed 's/ /\\040/g'
}

# The sshfs mount options, shared by the fstab and boot-script paths. Everything ssh
# needs rides -o (sshfs forwards unknown options), so root can mount with the USER's
# identity and pinned host key. ONLY ssh/sshfs-valid options here: nofail/_netdev are
# fstab words for mount(8)/systemd — a raw sshfs command hands them to libfuse, which
# refuses the whole mount ("fuse: unknown option", measured) — the fstab path appends
# them itself. BatchMode keeps a failed key auth from waiting on a prompt at boot.
sshfsauto_options() {
	_so_opts="reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,BatchMode=yes"
	_so_opts="$_so_opts,IdentityFile=$HOME_DIR/.ssh/machman_host"
	if [ -r "$HOME_DIR/.ssh/machman_known_hosts" ]; then
		_so_opts="$_so_opts,UserKnownHostsFile=$HOME_DIR/.ssh/machman_known_hosts"
		_so_opts="$_so_opts,StrictHostKeyChecking=yes"
	else
		_so_opts="$_so_opts,StrictHostKeyChecking=accept-new"
	fi
	_so_opts="$_so_opts,allow_other,uid=$(id -u "$U"),gid=$(id -g "$U")"
	printf '%s' "$_so_opts"
}

# sshfsauto_entry <name> → R_MOUNT_WHAT (source) + R_MOUNT_WHERE (mountpoint), both
# unescaped and empty when unknown. Two globals, never one packed string: host paths
# carry spaces as a rule (the share lives under "Application Support"), so any
# re-split downstream would truncate the source at the first one.
sshfsauto_entry() {
	R_MOUNT_WHAT=""
	R_MOUNT_WHERE=""
	if [ "$1" = "@share" ]; then
		R_MOUNT_WHAT="$HOST_USER@$GATEWAY:$SHARE_HOST_PATH"
		R_MOUNT_WHERE="$SHARE_ROOT"
		return 0
	fi
	_se_tab="$(printf '\t')"
	_se_path="$(printf '%s\n' "$MOUNTS_SSHFS" \
		| awk -F "$_se_tab" -v n="$1" '$1 == n { print $2; exit }')"
	[ -z "$_se_path" ] && return 0
	R_MOUNT_WHAT="$HOST_USER@$GATEWAY:$_se_path"
	R_MOUNT_WHERE="$MOUNTPOINT/$1"
	return 0
}

sshfsauto_act() {
	[ -n "$SSHFSAUTO_SELECTED" ] || return 0
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would configure boot mounts for: $(printf '%s' "$SSHFSAUTO_SELECTED" \
			| tr '\n' ',' | sed 's/,/, /g')"
		return 0
	fi
	_sa_opts="$(sshfsauto_options)"
	# The boot scripts run with the init's PATH — FreeBSD's rc has no /usr/local/bin,
	# where sshfs lives — so the resolved absolute path is embedded at install time.
	_sa_bin="$(command -v sshfs 2>/dev/null || echo sshfs)"
	_sa_fstab=""
	_sa_script=""
	_sa_old_ifs="$IFS"
	IFS='
'
	# shellcheck disable=SC2086
	set -f
	set -- $SSHFSAUTO_SELECTED
	set +f
	IFS="$_sa_old_ifs"
	for _sa_name in "$@"; do
		sshfsauto_entry "$_sa_name"
		[ -n "$R_MOUNT_WHAT" ] || {
			step_failed automount-sshfs \
				"no sshfs mount named \"$_sa_name\" on this VM — skipped" \
				"Check the VM's mounts in Machman, then re-run."
			continue
		}
		_sa_what="$R_MOUNT_WHAT"
		_sa_where="$R_MOUNT_WHERE"
		# The mount root is the user's: a link there was planted, and root never follows
		# one (no mkdir through it, chown -h).
		if [ -L "$_sa_where" ]; then
			step_failed automount-sshfs "$_sa_where is a symbolic link — skipped" \
				"Remove it, then re-run."
			continue
		fi
		mkdir -p "$_sa_where" 2>/dev/null || {
			step_failed automount-sshfs "could not create $_sa_where" \
				"Create it yourself and re-run."
			continue
		}
		chown -h "$U:$GROUP" "$_sa_where" 2>/dev/null || true
		if [ "$INIT" = systemd ]; then
			_sa_fstab="$_sa_fstab$(fstab_escape "$_sa_what") $(fstab_escape "$_sa_where")"
			_sa_fstab="$_sa_fstab fuse.sshfs noauto,x-systemd.automount,nofail,_netdev,$_sa_opts 0 0
"
		else
			# sh_quote, not bare '%s': source and mountpoint carry user text (VM names,
			# host paths) — one apostrophe in a bare-quoted word breaks the whole
			# generated rc script and can abort the rest of boot-local processing.
			_sa_script="${_sa_script}$(sh_quote "$_sa_bin") -o $(sh_quote "$_sa_opts")"
			_sa_script="$_sa_script $(sh_quote "$_sa_what") $(sh_quote "$_sa_where") || true
"
		fi
		SSHFSAUTO_DONE="$SSHFSAUTO_DONE $_sa_name"
		AUTOMOUNT_LINES="${AUTOMOUNT_LINES:+$AUTOMOUNT_LINES
}sshfs	$_sa_name	$_sa_where"
	done
	SSHFSAUTO_DONE="${SSHFSAUTO_DONE# }"
	[ -n "$SSHFSAUTO_DONE" ] || return 0
	if [ "$INIT" = systemd ]; then
		# The block is shared; each feature rewrites only its own lines: the share's
		# virtiofs line stays as it is, ahead of the sshfs ones.
		_sa_keep="$(fstab_block_lines eq virtiofs)"
		if ! put_block /etc/fstab "$MARKER" "${_sa_keep:+$_sa_keep
}$_sa_fstab"; then
			step_failed automount-sshfs "could not update /etc/fstab: $R_ERROR" \
				"Add the sshfs lines yourself."
			return 0
		fi
		run "reloading systemd mounts" systemctl daemon-reload || true
		ok "sshfs folders mount on first access ($SSHFSAUTO_DONE)"
		note "They connect once you approve this VM in Machman (guest -> host SSH)."
	else
		sshfsauto_write_boot_script "$_sa_script"
	fi
	return 0
}

# Non-systemd boot hook: alpine/openrc -> /etc/local.d, everything else with an
# /etc/rc.local -> a marker block there. Best-effort by design; the report says which.
sshfsauto_write_boot_script() {
	case "$INIT" in
	openrc)
		{
			printf '#!/bin/sh\n# %s — machman sshfs automounts\n' "$MARKER"
			printf '%s' "$1"
		} > /etc/local.d/machman-sshfs.start
		chmod 755 /etc/local.d/machman-sshfs.start
		run "enabling the local boot scripts" rc-update add local default || true
		ok "sshfs folders mount at boot (/etc/local.d/machman-sshfs.start)"
		;;
	*)
		if ! rc_local_ready automount-sshfs; then
			step_failed automount-sshfs \
				"/etc/rc.local is not executable, so the boot mounts will not run" \
				"chmod +x /etc/rc.local if everything in it should run at boot, then re-run."
			return 0
		fi
		if ! rc_local_put "$MARKER" "$1"; then
			step_failed automount-sshfs "could not update /etc/rc.local: $R_ERROR" \
				"Add the sshfs lines to it yourself."
			return 0
		fi
		ok "sshfs folders mount at boot (/etc/rc.local)"
		;;
	esac
	note "They connect once you approve this VM in Machman (guest -> host SSH)."
	return 0
}

sshfsauto_report() {
	return 0
}

sshfsauto_uninstall() {
	rm -f /etc/local.d/machman-sshfs.start 2>/dev/null || true
	strip_block /etc/rc.local || uninstall_kept
	return 0
}
