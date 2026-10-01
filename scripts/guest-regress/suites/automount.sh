# The shared fstab block (systemd guests): each automount feature rewrites only its own
# lines, and mount names are never globbed.
# CHECKS: VFS_KEEPS_SSHFS GLOB_TAG
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
exit 0
