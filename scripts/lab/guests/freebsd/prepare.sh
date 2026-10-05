#!/bin/sh
# Runs once, as root, inside a fresh FreeBSD BASIC-CLOUDINIT image while the lab prepares it
# (nuageinit's runcmd; scripts/lab/qemu/prepare.sh runs it over ssh where nuageinit did not).
# nuageinit has created the user lab (wheel, the baked key) and installed the packages; this
# makes sure of them, pins doas/sudo to lab, writes a manifest and the marker the host waits
# for. Network: open (MACHMAN_LAB_PREPARE=1); per-run boots never fetch anything.
set -u
D=/var/db/machman-lab
mkdir -p "$D"
exec >"$D/prepare.log" 2>&1
set -x
export ASSUME_ALWAYS_YES=yes
for p in doas sudo fusefs-sshfs; do
	pkg info -e "$p" || pkg install -y "$p" || { echo "prepare: pkg install $p failed"; exit 1; }
done
printf 'permit nopass lab\npermit nopass root\n' > /usr/local/etc/doas.conf
chmod 600 /usr/local/etc/doas.conf
mkdir -p /usr/local/etc/sudoers.d
echo 'lab ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/lab
chmod 440 /usr/local/etc/sudoers.d/lab
sysrc sshd_enable=YES
# The image's first-boot base upgrade ran once already (firstboot_pkg_upgrade): a per-run
# boot has no network for it.
sysrc firstboot_pkg_upgrade_enable=NO
pkg clean -ay
{
	echo "freebsd-version-k $(freebsd-version -k)"
	echo "freebsd-version-u $(freebsd-version -u)"
	echo "uname $(uname -rm)"
	pkg query '%n %v' | sort
} > "$D/manifest"
touch "$D/prepared"
