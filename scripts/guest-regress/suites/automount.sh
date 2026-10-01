# The shared fstab block (systemd guests): each automount feature rewrites only its own
# lines.
# CHECKS: VFS_KEEPS_SSHFS
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
fake_systemd
mkuser reg
block() { awk -v m="$NEW" '$0 == "# BEGIN " m { b = 1; next } $0 == "# END " m { b = 0 } b' /etc/fstab; }

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
exit 0
