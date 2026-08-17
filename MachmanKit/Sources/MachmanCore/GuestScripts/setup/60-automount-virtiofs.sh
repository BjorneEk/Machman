# === machman-setup: 60-automount-virtiofs ===
# Feature: mount the Machman share at boot. One marker-tagged fstab block — everything
# (host mounts and the installers) is a subdirectory of the one share, so this single
# line is the whole feature. mount(2) autoloads the virtiofs module by name; nofail keeps
# a share-less boot booting.

VFSAUTO_PLAN=""
VFSAUTO_MOUNT_NOW=""
AUTOMOUNT_LINES=""         # kind<TAB>target<TAB>path, collected for state + report
F_AVAIL_vfsauto=0
F_REASON_vfsauto=""

vfsauto_detect() {
	detect_virtiofs
	return 0
}

vfsauto_configured() {
	grep -q "^# BEGIN $MARKER" /etc/fstab 2>/dev/null \
		&& grep -q " $SHARE_ROOT " /etc/fstab 2>/dev/null
}

vfsauto_available() {
	F_AVAIL_vfsauto=0
	F_REASON_vfsauto=""
	if [ "$OS_FAMILY" = darwin ]; then
		F_REASON_vfsauto="macOS automounts the share itself"
		return 0
	fi
	if [ "$VIRTIOFS_OK" -eq 0 ]; then
		F_REASON_vfsauto="no virtiofs driver in this guest — sshfs automount covers the share instead"
		return 0
	fi
	F_AVAIL_vfsauto=1
	return 0
}

vfsauto_decide() {
	if vfsauto_configured; then
		VFSAUTO_PLAN="$SHARE_ROOT already in fstab — refresh the entry"
	else
		VFSAUTO_PLAN="$SHARE_TAG -> $SHARE_ROOT (fstab, nofail)"
	fi
	if mount 2>/dev/null | grep -q " $SHARE_ROOT "; then
		VFSAUTO_MOUNT_NOW=0
	else
		ask_yes_no "Mount the share now as well (not just at boot)?" y
		VFSAUTO_MOUNT_NOW="$R_YES"
	fi
	return 0
}

vfsauto_plan() {
	plan_line "share automount" "$VFSAUTO_PLAN"
	return 0
}

vfsauto_act() {
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add '$SHARE_TAG $SHARE_ROOT virtiofs rw,nofail' to /etc/fstab"
		return 0
	fi
	mkdir -p "$SHARE_ROOT" 2>/dev/null || {
		step_failed automount-virtiofs "could not create $SHARE_ROOT" \
			"Create it yourself, then re-run."
		return 0
	}
	touch /etc/fstab
	strip_block /etc/fstab
	{
		printf '# BEGIN %s\n' "$MARKER"
		printf '%s %s virtiofs rw,nofail 0 0\n' "$SHARE_TAG" "$SHARE_ROOT"
		printf '# END %s\n' "$MARKER"
	} >> /etc/fstab
	ok "the share mounts at boot ($SHARE_ROOT)"
	AUTOMOUNT_LINES="virtiofs	$SHARE_TAG	$SHARE_ROOT"
	if [ "$VFSAUTO_MOUNT_NOW" = 1 ]; then
		run "mounting the share now" mount "$SHARE_ROOT" \
			|| step_failed automount-virtiofs "could not mount $SHARE_ROOT now" \
				"It still mounts at the next boot; try: mount $SHARE_ROOT"
	fi
	return 0
}

vfsauto_report() {
	return 0
}

vfsauto_uninstall() {
	# The fstab block is shared with the sshfs automounts; the uninstall driver strips it
	# once. Nothing feature-specific beyond that.
	return 0
}
