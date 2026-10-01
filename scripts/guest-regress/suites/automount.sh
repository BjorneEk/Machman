# The shared fstab block (systemd guests): each automount feature rewrites only its own
# lines, and mount names are never globbed.
# CHECKS: VFS_KEEPS_SSHFS SSHFS_RECORD_KEPT GLOB_TAG SHARE_PATH_REPORT_ONLY
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
fake_systemd
mkuser reg
block() {
	awk -v m="$NEW" '$0 == "# BEGIN " m { b = 1; next } $0 == "# END " m { b = 0 } b' /etc/fstab
}

$SH "$S" -y --user reg --two-way --automount-virtiofs --automount-sshfs --no-install \
	--no-service >/tmp/run1.log 2>&1
[ "$(block | grep -c fuse.sshfs)" = 2 ] || R VFS_KEEPS_SSHFS "uncalibrated"
# A later run that refreshes only the share must leave the sshfs lines alone.
$SH "$S" -y --user reg --automount-virtiofs --no-automount-sshfs --one-way --no-sshfs \
	--no-install --no-service >/tmp/run2.log 2>&1
if [ "$(block | grep -c fuse.sshfs)" = 2 ] && [ "$(block | grep -c ' virtiofs ')" = 1 ] \
	&& [ "$(block | head -n 1 | awk '{ print $3 }')" = virtiofs ]; then
	R VFS_KEEPS_SSHFS pass
else
	R VFS_KEEPS_SSHFS fail; cat /etc/fstab
fi
# …and so does what the guest remembers and reports about them.
if grep -q "^AUTOMOUNT_SSHFS='projects docs'" /var/lib/machman/state.env \
	&& grep -q '^AUTOMOUNT_[0-9]*=sshfs projects /mnt/machman/mounts/projects$' "$REPORT" \
	&& grep -q '^AUTOMOUNT_[0-9]*=virtiofs host-share /mnt/machman/share$' "$REPORT"; then
	R SSHFS_RECORD_KEPT pass
else
	R SSHFS_RECORD_KEPT fail; cat /var/lib/machman/state.env; grep AUTOMOUNT "$REPORT"
fi
$SH "$S" --uninstall -y >/dev/null 2>&1

# A mount named like a glob, run from a directory full of files.
printf 'sshfs\t*\t/Users/g/Star\nsshfs\tdocs\t/Users/g/My Docs\n' \
	> /mnt/machman/share/GuestSetup/mounts.list
mkdir -p /tmp/cwd && cd /tmp/cwd && touch a.txt b.txt
$SH "$S" -y --user reg --two-way --automount-sshfs --no-install --no-service \
	>/tmp/glob.log 2>&1
if grep -qF '/mnt/machman/mounts/* fuse.sshfs' /etc/fstab \
	&& ! grep -q 'a.txt' /etc/fstab && ! grep -q 'no sshfs mount named' /tmp/glob.log; then
	R GLOB_TAG pass
else
	R GLOB_TAG fail; grep -n 'sshfs' /etc/fstab; grep 'named' /tmp/glob.log
fi
$SH "$S" --uninstall -y >/dev/null 2>&1

# S9: a guest without virtiofs mounts the share itself over sshfs ("@share"); --report-only
# (the boot-time refresh) lists it where its fstab entry mounts it. Seeded: the containers
# all have a virtiofs driver, so the script never offers "@share" here.
mkdir -p /var/lib/machman
printf "STATE_VERSION=1\nSCRIPT_VERSION=4\nMARKER='%s'\nCONFIGURED='sshfsauto'\n" "$NEW" \
	> /var/lib/machman/state.env
printf "LAST_STATUS='ok'\nAUTOMOUNT_SSHFS='@share docs'\nMOUNTPOINT='/mnt/machman/mounts'\n" \
	>> /var/lib/machman/state.env
$SH "$S" --report-only -q >/tmp/ro.log 2>&1
if grep -q '^AUTOMOUNT_[0-9]*=sshfs @share /mnt/machman/share$' "$REPORT" \
	&& grep -q '^AUTOMOUNT_[0-9]*=sshfs docs /mnt/machman/mounts/docs$' "$REPORT"; then
	R SHARE_PATH_REPORT_ONLY pass
else
	R SHARE_PATH_REPORT_ONLY fail; grep AUTOMOUNT "$REPORT"
fi
exit 0
