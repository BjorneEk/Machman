# === machman-setup: 55-sshfs ===
# Feature: sshfs in the guest — the tool that mounts host folders over the guest -> host
# link. Two deliberately separate halves (the v2 reasoning): the fuse module and a mount
# point are harmless plumbing; vfs.usermount is a system-wide permission that is never
# assumed, never implied, never silent.

SSHFS_PLAN=""
MOUNT_PLAN=""
SYSCTL_CONF=/etc/sysctl.conf   # where an allowed user mount is kept across reboots
USER_MOUNT_PLAN=""
avail_sshfs=0
reason_sshfs=""

sshfs_detect() {
	detect_sshfs
	return 0
}

sshfs_is_configured() {
	[ "$SSHFS" -eq 1 ]
}

sshfs_menu_note() {
	if [ "$SSHFS" -eq 1 ]; then
		echo "installed${SSHFS_VERSION:+ ($SSHFS_VERSION)} — verify"
	else
		echo "install the tool that mounts host folders"
	fi
	return 0
}

sshfs_menu_default() {
	if state_was_configured sshfs; then echo 1; else echo 0; fi
	return 0
}

sshfs_available() {
	avail_sshfs=0
	reason_sshfs=""
	if [ "$OS_FAMILY" = darwin ]; then
		reason_sshfs="macOS needs macFUSE — install it yourself"
		return 0
	fi
	if [ "$SSHFS" -eq 0 ] && ! any_pm_present; then
		reason_sshfs="not installed and no package manager to install it with"
		return 0
	fi
	avail_sshfs=1
	return 0
}

sshfs_decide() {
	if [ "$SSHFS" -eq 1 ]; then
		SSHFS_PLAN="already installed${SSHFS_VERSION:+ ($SSHFS_VERSION)} — report the capability"
	else
		SSHFS_PLAN="install ($(pkg_for_sshfs))"
	fi
	MOUNT_PLAN="$MOUNTPOINT"
	[ -d "$MOUNTPOINT" ] && MOUNT_PLAN="$MOUNT_PLAN (exists)"
	if ! fuse_loaded; then
		MOUNT_PLAN="$MOUNT_PLAN, load fusefs"
	fi
	if [ "$OS_FAMILY" = freebsd ] && [ "$FUSE_PERSISTED" -eq 0 ]; then
		MOUNT_PLAN="$MOUNT_PLAN, keep fusefs across reboots"
	fi
	USER_MOUNT_PLAN=""
	if [ "$OS_FAMILY" = openbsd ]; then
		# OpenBSD removed kern.usermount in 5.7 — there is no knob to offer.
		USER_MOUNT_PLAN="root only (OpenBSD has no user mounts)"
		WANT_MOUNT_SETUP=0
	elif user_mounts_allowed; then
		USER_MOUNT_PLAN="already allowed"
		WANT_MOUNT_SETUP=0
	else
		if [ -z "$WANT_MOUNT_SETUP" ]; then
			ask_yes_no "Let ANY user of this guest mount filesystems ($(usermount_knob)=1)? Root can mount without it." n
			WANT_MOUNT_SETUP="$R_YES"
		fi
		if [ "$WANT_MOUNT_SETUP" = 1 ]; then
			USER_MOUNT_PLAN="enable $(usermount_knob)=1"
		else
			USER_MOUNT_PLAN="left off — mount as root"
		fi
	fi
	return 0
}

sshfs_plan() {
	plan_line "sshfs" "$SSHFS_PLAN"
	plan_line "mount point" "$MOUNT_PLAN"
	[ -n "$USER_MOUNT_PLAN" ] && plan_line "user mounts" "$USER_MOUNT_PLAN"
	return 0
}

# The plumbing: a loaded (and still-loaded-next-boot) fuse driver, and somewhere to mount.
sshfs_act_fuse_ready() {
	if [ "$OS_FAMILY" = freebsd ]; then
		if ! fuse_loaded; then
			run "loading the fuse module" kldload fusefs \
				|| step_failed sshfs "could not load the fusefs module" \
					"Load it yourself: kldload fusefs"
		fi
		if [ "$FUSE_PERSISTED" -eq 0 ]; then
			# A driver that is not loaded at boot just breaks the next mount.
			kld_list_add fusefs \
				|| step_failed sshfs "could not persist the fusefs module" \
					"Add it yourself: sysrc kld_list+=fusefs"
		fi
	fi
	if [ ! -d "$MOUNTPOINT" ]; then
		run "creating $MOUNTPOINT" mkdir -p "$MOUNTPOINT" \
			|| step_failed sshfs "could not create $MOUNTPOINT" \
				"Create it yourself, or pass --mountpoint <path>."
	fi
	if [ -d "$MOUNTPOINT" ] || [ "$DRY_RUN" -eq 1 ]; then
		run "giving $U the mount point" chown -h "$U:$GROUP" "$MOUNTPOINT" || true
	fi
	# Ready only when it is: a failed module load or mkdir said why above.
	if [ "$DRY_RUN" -eq 0 ] && [ -d "$MOUNTPOINT" ] && fuse_loaded; then
		ok "$MOUNTPOINT is ready for host folders"
	fi
	return 0
}

# The permission. Only ever reached when the user said yes to exactly this. It is kept for
# the next boot whether or not the running system takes it: NetBSD's rc raises
# kern.securelevel to 1, which refuses raising the knob now, and applies sysctl.conf before
# that at the next boot.
sshfs_act_user_mounts() {
	[ "$WANT_MOUNT_SETUP" = "1" ] || return 0
	_sau_knob="$(usermount_knob)"
	[ -n "$_sau_knob" ] || return 0
	# NetBSD's sysctl sets with -w; FreeBSD's takes name=value as it is.
	_sau_w=""
	[ "$OS_FAMILY" = netbsd ] && _sau_w=-w
	if run "allowing user mounts" sysctl ${_sau_w:+"$_sau_w"} "$_sau_knob=1"; then
		ok "user mounts allowed ($_sau_knob=1)"
	elif _sau_level="$(sysctl -n kern.securelevel 2>/dev/null)" \
		&& [ "${_sau_level:-0}" -gt 0 ] 2>/dev/null; then
		note "$_sau_knob=1 takes effect at the next boot (securelevel $_sau_level refuses it now)."
	else
		step_failed mount-setup "could not set $_sau_knob" \
			"Set it yourself: sysctl ${_sau_w:+$_sau_w }$_sau_knob=1"
	fi
	sshfs_keep_sysctl "$_sau_knob" 1
	return 0
}

# sshfs_keep_sysctl <name> <value> — kept across reboots in SYSCTL_CONF, in a block tagged
# $MARKER-usermount that the uninstall can name; a file already setting it is left alone.
sshfs_keep_sysctl() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would keep $1=$2 in $SYSCTL_CONF"
		return 0
	fi
	_sks_name="$(printf '%s' "$1" | sed 's/\./\\./g')"
	grep -Eq "^[[:space:]]*${_sks_name}[[:space:]]*=[[:space:]]*${2}[[:space:]]*\$" \
		"$SYSCTL_CONF" 2>/dev/null && return 0
	if ! put_block "$SYSCTL_CONF" "$MARKER-usermount" "$1=$2"; then
		step_failed mount-setup "could not keep $1=$2 across reboots: $R_ERROR" \
			"Add '$1=$2' to $SYSCTL_CONF yourself."
	fi
	return 0
}

sshfs_act() {
	if [ "$SSHFS" -eq 0 ]; then
		# shellcheck disable=SC2086
		if pm_install $(pkg_for_sshfs); then
			SSHFS=1
			SSHFS_VERSION="$(sshfs --version 2>&1 \
				| sed -n 's/.*[Ss][Ss][Hh][Ff][Ss] version //p' | head -n 1 || true)"
			ok "sshfs installed${SSHFS_VERSION:+ ($SSHFS_VERSION)}"
		else
			step_failed sshfs "could not install sshfs${R_ERROR:+: $R_ERROR}" \
				"Install it yourself and re-run; everything else is unaffected."
			return 0
		fi
	fi
	sshfs_act_fuse_ready
	sshfs_act_user_mounts
	if [ "$SSHFS" -eq 1 ] && fuse_loaded && user_mounts_allowed; then
		SSHFS_MOUNT_OK=1
	fi
	return 0
}

sshfs_report() {
	printf 'SSHFS=%s\n' "$SSHFS"
	[ -n "$SSHFS_VERSION" ] && printf 'SSHFS_VERSION=%s\n' "$SSHFS_VERSION"
	printf 'SSHFS_MOUNT_OK=%s\n' "$SSHFS_MOUNT_OK"
	[ "$SSHFS" -eq 1 ] && printf 'SSHFS_MOUNTROOT=%s\n' "$MOUNTPOINT"
	return 0
}

sshfs_uninstall() {
	# The package and the sysctl stay: both may serve the user beyond Machman, and v2
	# never removed them either. The kld_list entry stays with the package — sshfs
	# without a boot-loaded fusefs just breaks mysteriously on the next reboot. All
	# deliberate keeps of what a run added are DISCLOSED here, with their one-line reverts.
	if [ "$OS_FAMILY" = freebsd ] && kld_list_ours fusefs; then
		note "kld_list keeps fusefs (sshfs stays usable) — 'sysrc kld_list-=fusefs' reverts it."
	fi
	_su_knob="$(usermount_knob)"
	# Machman's only while this VM's block keeps it (on now, or from the next boot where a
	# securelevel refused it): one the guest or its admin turned on is theirs to mention.
	if [ -n "$_su_knob" ] \
		&& grep -qxF "# BEGIN $MARKER-usermount" "$SYSCTL_CONF" 2>/dev/null; then
		_su_off="sysctl $_su_knob=0"
		[ "$OS_FAMILY" = netbsd ] && _su_off="sysctl -w $_su_knob=0"
		note "$_su_knob=1 stays — '$_su_off' and the $MARKER-usermount block in $SYSCTL_CONF revert it."
	fi
	return 0
}
