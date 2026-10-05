#!/bin/sh
# Runs once, as root over ssh, inside the Debian nocloud image while the lab prepares it
# (scripts/lab/qemu/prepare.sh build debian; open network). Installs what the guest-regress
# suites and the lab's Debian rows need, grows the root file system into the 8 GiB disk,
# leaves hvc2 to the lab's console driver (never a console under test), writes a manifest and
# the marker the host waits for. Per-run boots never fetch anything.
set -eu
D=/var/lib/machman-lab
mkdir -p "$D"
exec >"$D/prepare.log" 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends openssh-server openssh-client sshfs fuse3 sudo \
	doas nftables iproute2 procps grub2-common cloud-guest-utils
# The image's root partition stays at its 3 GiB unless grown.
root="$(findmnt -n -o SOURCE /)"
growpart "${root%%[0-9]*}" "${root##*[!0-9]}" || true
resize2fs "$root"
# The kernel the image ships must carry what the rows use; otherwise take the distro's.
for m in virtiofs fuse nf_tables; do
	modinfo "$m" >/dev/null 2>&1 || need_kernel=1
done
[ -z "${need_kernel:-}" ] || apt-get install -y -qq linux-image-arm64
systemctl enable serial-getty@hvc2.service
# Restricted per-run networking drops DNS (10.0.2.3): name the lab's addresses locally.
printf '10.0.2.2\tlab-slirp-host\n10.0.2.100\tlab-gateway\n' >> /etc/hosts
apt-get clean
fstrim -av || true
{
	echo "debian $(cat /etc/debian_version)"
	echo "pid1 $(ps -o comm= -p 1)"
	echo "uname $(uname -r)"
	dpkg-query -W -f '${Package} ${Version}\n' | sort
} > "$D/manifest"
touch "$D/prepared"
