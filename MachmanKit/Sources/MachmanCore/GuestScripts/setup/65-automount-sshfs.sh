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

sshfsauto_configured() {
	[ -n "$ST_AUTOMOUNT_SSHFS" ] \
		|| { grep -q "^# BEGIN $MARKER" /etc/fstab 2>/dev/null \
			&& grep -q "fuse.sshfs" /etc/fstab 2>/dev/null; }
}

sshfsauto_items() {
	[ "$VIRTIOFS_OK" -eq 0 ] && [ "$OS_FAMILY" != darwin ] \
		&& echo "@share   the Machman share (installers + reports)"
	for _si_name in $MOUNTS_SSHFS_NAMES; do
		echo "$_si_name"
	done
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
	_sd_count="$(printf '%s\n' "$_sd_items" | sed '/^$/d' | wc -l | tr -d ' ')"
	if [ "$_sd_count" = 1 ]; then
		SSHFSAUTO_SELECTED="$(printf '%s\n' "$_sd_items" | awk '{ print $1; exit }')"
	else
		_sd_marks=""
		_sd_i=1
		while [ "$_sd_i" -le "$_sd_count" ]; do
			toggle_mark "$_sd_marks" "$_sd_i"
			_sd_marks="$R_MARKS"
			_sd_i=$((_sd_i + 1))
		done
		menu_multi "Mount which host folders at boot (over sshfs)?" "$_sd_items" "$_sd_marks"
		_sd_i=1
		for _sd_first in $(printf '%s\n' "$_sd_items" | awk '{ print $1 }'); do
			case ",$R_MARKS," in
			*",$_sd_i,"*) SSHFSAUTO_SELECTED="$SSHFSAUTO_SELECTED $_sd_first" ;;
			esac
			_sd_i=$((_sd_i + 1))
		done
		SSHFSAUTO_SELECTED="${SSHFSAUTO_SELECTED# }"
	fi
	SSHFSAUTO_PLAN="${SSHFSAUTO_SELECTED:-none} (as $U, needs guest -> host approval)"
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
# identity and pinned host key.
sshfsauto_options() {
	_so_opts="reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,nofail,_netdev"
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

# sshfsauto_entry <name> → R_ITEM = "<what> <where>" (unescaped), empty when unknown
sshfsauto_entry() {
	if [ "$1" = "@share" ]; then
		R_ITEM="$HOST_USER@$GATEWAY:$SHARE_HOST_PATH $SHARE_ROOT"
		return 0
	fi
	_se_tab="$(printf '\t')"
	_se_path="$(printf '%s\n' "$MOUNTS_SSHFS" \
		| awk -F "$_se_tab" -v n="$1" '$1 == n { print $2; exit }')"
	if [ -z "$_se_path" ]; then
		R_ITEM=""
		return 0
	fi
	R_ITEM="$HOST_USER@$GATEWAY:$_se_path $MOUNTPOINT/$1"
	return 0
}

sshfsauto_act() {
	[ -n "$SSHFSAUTO_SELECTED" ] || return 0
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would configure boot mounts for: $SSHFSAUTO_SELECTED"
		return 0
	fi
	_sa_opts="$(sshfsauto_options)"
	_sa_fstab=""
	_sa_script=""
	for _sa_name in $SSHFSAUTO_SELECTED; do
		sshfsauto_entry "$_sa_name"
		[ -n "$R_ITEM" ] || continue
		_sa_what="${R_ITEM%% *}"
		_sa_where="${R_ITEM#* }"
		mkdir -p "$_sa_where" 2>/dev/null || {
			step_failed automount-sshfs "could not create $_sa_where" \
				"Create it yourself and re-run."
			continue
		}
		chown "$U:$GROUP" "$_sa_where" 2>/dev/null || true
		if [ "$INIT" = systemd ]; then
			_sa_fstab="$_sa_fstab$(fstab_escape "$_sa_what") $(fstab_escape "$_sa_where")"
			_sa_fstab="$_sa_fstab fuse.sshfs noauto,x-systemd.automount,$_sa_opts 0 0
"
		else
			_sa_script="${_sa_script}sshfs -o $_sa_opts '$_sa_what' '$_sa_where' || true
"
		fi
		SSHFSAUTO_DONE="$SSHFSAUTO_DONE $_sa_name"
		AUTOMOUNT_LINES="${AUTOMOUNT_LINES:+$AUTOMOUNT_LINES
}sshfs	$_sa_name	$_sa_where"
	done
	SSHFSAUTO_DONE="${SSHFSAUTO_DONE# }"
	[ -n "$SSHFSAUTO_DONE" ] || return 0
	if [ "$INIT" = systemd ]; then
		# Shares the marker block with the virtiofs line: rebuild the block whole.
		touch /etc/fstab
		_sa_keep=""
		if grep -q "^# BEGIN $MARKER" /etc/fstab 2>/dev/null; then
			_sa_keep="$(awk -v m="$MARKER" '
				$0 == "# BEGIN " m { inb = 1; next }
				$0 == "# END " m { inb = 0; next }
				inb && $3 == "virtiofs" { print }
			' /etc/fstab)"
		fi
		strip_block /etc/fstab
		{
			printf '# BEGIN %s\n' "$MARKER"
			[ -n "$_sa_keep" ] && printf '%s\n' "$_sa_keep"
			printf '%s' "$_sa_fstab"
			printf '# END %s\n' "$MARKER"
		} >> /etc/fstab
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
		if [ ! -f /etc/rc.local ]; then
			printf '#!/bin/sh\n' > /etc/rc.local
			chmod 755 /etc/rc.local
		fi
		strip_block /etc/rc.local
		{
			printf '# BEGIN %s\n' "$MARKER"
			printf '%s' "$1"
			printf '# END %s\n' "$MARKER"
		} >> /etc/rc.local
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
	[ -f /etc/rc.local ] && strip_block /etc/rc.local
	return 0
}
