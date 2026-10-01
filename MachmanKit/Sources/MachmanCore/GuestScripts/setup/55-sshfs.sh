# === machman-setup: 55-sshfs ===
# Feature: sshfs in the guest — the tool that mounts host folders over the guest -> host
# link. Two deliberately separate halves (the v2 reasoning): the fuse module and a mount
# point are harmless plumbing; vfs.usermount is a system-wide permission that is never
# assumed, never implied, never silent.

SSHFS_PLAN=""
MOUNT_PLAN=""
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
			ask_yes_no "Let ANY user of this guest mount filesystems (vfs.usermount=1)? Root can mount without it." n
			WANT_MOUNT_SETUP="$R_YES"
		fi
		if [ "$WANT_MOUNT_SETUP" = 1 ]; then
			USER_MOUNT_PLAN="enable vfs.usermount=1"
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
			run "keeping fusefs across reboots" sysrc "kld_list+=fusefs" \
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
	ok "$MOUNTPOINT is ready for host folders"
	return 0
}

# The permission. Only ever reached when the user said yes to exactly this.
sshfs_act_user_mounts() {
	[ "$WANT_MOUNT_SETUP" = "1" ] || return 0
	[ "$OS_FAMILY" = freebsd ] || return 0
	if ! run "allowing user mounts" sysctl vfs.usermount=1; then
		step_failed mount-setup "could not set vfs.usermount" \
			"Set it yourself: sysctl vfs.usermount=1"
		return 0
	fi
	if [ "$DRY_RUN" -eq 0 ] && ! grep -q '^vfs.usermount' /etc/sysctl.conf 2>/dev/null; then
		echo 'vfs.usermount=1' >> /etc/sysctl.conf
	fi
	ok "user mounts allowed (vfs.usermount=1)"
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
	# deliberate keeps are DISCLOSED here, with their one-line reverts.
	if [ "$OS_FAMILY" = freebsd ]; then
		if sysrc -n kld_list 2>/dev/null | grep -q fusefs; then
			note "kld_list keeps fusefs (sshfs stays usable) — 'sysrc kld_list-=fusefs' reverts it."
		fi
		if [ "$(sysctl -n vfs.usermount 2>/dev/null || true)" = 1 ]; then
			note "vfs.usermount=1 stays — 'sysctl vfs.usermount=0' plus its /etc/sysctl.conf line revert it."
		fi
	fi
	return 0
}
