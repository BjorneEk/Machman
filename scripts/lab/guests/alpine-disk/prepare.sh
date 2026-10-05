#!/bin/sh
# Runs once, as root (doas over ssh), inside Alpine's generic cloud image while the lab
# prepares it (scripts/lab/qemu/prepare.sh build alpine-disk; open network). Installs what the Guest Setup
# rows use, grows the root file system into the disk, gives the lab's console driver a getty
# on hvc2, empties root's password for console logins, switches cloud-init off, writes a
# manifest and the marker the host waits for. Per-run boots never fetch anything.
set -eu
D=/var/lib/machman-lab
mkdir -p "$D"
exec >"$D/prepare.log" 2>&1
set -x
apk update
apk add openssh openssh-server openssh-client-default openssh-sftp-server sshfs fuse3 doas \
	sudo nftables util-linux procps-ng iproute2 coreutils findutils diffutils grep sed shadow \
	e2fsprogs-extra cloud-utils-growpart
# The image's root partition stays at its first size unless grown.
root="$(findmnt -n -o SOURCE /)"
disk="/dev/$(lsblk -n -o PKNAME "$root")"
part="$(cat "/sys/class/block/${root#/dev/}/partition")"
growpart "$disk" "$part" || true
resize2fs "$root" || true
# The kernel must carry what the rows use; otherwise take the distro's virt kernel.
need_kernel=""
for m in virtiofs fuse nf_tables; do
	modinfo "$m" >/dev/null 2>&1 || need_kernel=1
done
[ -z "$need_kernel" ] || apk add linux-virt
rc-update add sshd default
# nftables at boot, with an empty ruleset until a test writes its own.
printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.nft
rc-update add nftables boot
# hvc2: the lab's console driver (never a console under test); root logs in without a password.
grep -q '^hvc2:' /etc/inittab || echo 'hvc2::respawn:/sbin/getty -L 115200 hvc2 vt100' >> /etc/inittab
for t in hvc0 hvc1 hvc2; do
	grep -qx "$t" /etc/securetty 2>/dev/null || echo "$t" >> /etc/securetty
done
passwd -d root
# Restricted per-run networking drops DNS (10.0.2.3): name the lab's addresses locally.
printf '10.0.2.2\tlab-slirp-host\n10.0.2.100\tlab-gateway\n127.0.0.1\t%s\n' "$(hostname)" \
	>> /etc/hosts
# cloud-init ran once (root's key, the network); later boots must not run it again.
touch /etc/cloud/cloud-init.disabled
{
	echo "alpine $(cat /etc/alpine-release)"
	echo "pid1 $(ps -o comm= -p 1 2>/dev/null || cat /proc/1/comm)"
	echo "uname $(uname -r)"
	apk info -v | sort
} > "$D/manifest"
fstrim -av || true
touch "$D/prepared"
