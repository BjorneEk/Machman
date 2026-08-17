# === machman-setup: 60-automount-virtiofs ===
# Feature: mount the Machman share at boot. One marker-tagged fstab block — everything
# (host mounts and the installers) is a subdirectory of the one share, so this single
# line is the whole feature. mount(2) autoloads the virtiofs module by name; nofail keeps
# a share-less boot booting.

VFSAUTO_PLAN=""
VFSAUTO_MOUNT_NOW=""
AUTOMOUNT_LINES=""         # kind<TAB>target<TAB>path, collected for state + report
avail_vfsauto=0
reason_vfsauto=""

vfsauto_detect() {
	detect_virtiofs
	return 0
}

vfsauto_configured() {
	grep -q "^# BEGIN $MARKER" /etc/fstab 2>/dev/null \
		&& grep -q " $SHARE_ROOT " /etc/fstab 2>/dev/null
}

# A share mount in fstab that is NOT inside our marker block: someone else's entry.
vfsauto_foreign() {
	[ -f /etc/fstab ] || return 1
	awk -v m="$MARKER" -v tag="$SHARE_TAG" -v root="$SHARE_ROOT" '
		$0 == "# BEGIN " m { inb = 1; next }
		$0 == "# END " m { inb = 0; next }
		inb || /^[[:space:]]*#/ || NF < 2 { next }
		$1 == tag || $2 == root { found = 1 }
		END { exit found ? 0 : 1 }
	' /etc/fstab
}

vfsauto_is_configured() {
	vfsauto_configured || vfsauto_foreign
}

vfsauto_menu_note() {
	if vfsauto_configured; then
		echo "fstab entry present — refresh"
	elif vfsauto_foreign; then
		echo "configured outside Machman — report only"
	else
		echo "mount the share at boot (fstab)"
	fi
	return 0
}

vfsauto_menu_default() {
	echo 1
	return 0
}

vfsauto_available() {
	avail_vfsauto=0
	reason_vfsauto=""
	if [ "$OS_FAMILY" = darwin ]; then
		reason_vfsauto="macOS automounts the share itself"
		return 0
	fi
	if [ "$VIRTIOFS_OK" -eq 0 ]; then
		reason_vfsauto="no virtiofs driver in this guest — sshfs automount covers the share instead"
		return 0
	fi
	avail_vfsauto=1
	return 0
}

VFSAUTO_ACTION="install"   # install | refresh | report

vfsauto_decide() {
	VFSAUTO_MOUNT_NOW=0
	if vfsauto_foreign && ! vfsauto_configured; then
		# Someone else's fstab entry mounts the share — not ours to rewrite.
		VFSAUTO_ACTION=report
		VFSAUTO_PLAN="left alone — an fstab entry outside Machman already mounts it"
		return 0
	fi
	if vfsauto_configured; then
		VFSAUTO_ACTION=refresh
		VFSAUTO_PLAN="refresh: $SHARE_TAG -> $SHARE_ROOT (fstab, nofail)"
	else
		VFSAUTO_ACTION=install
		VFSAUTO_PLAN="install: $SHARE_TAG -> $SHARE_ROOT (fstab, nofail)"
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
	if [ "$VFSAUTO_ACTION" = report ]; then
		note "share automount left as is (configured outside Machman)."
		return 0
	fi
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
