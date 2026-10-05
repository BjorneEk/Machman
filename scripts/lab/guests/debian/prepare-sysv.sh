#!/bin/sh
# Turns a prepared Debian lab image into a sysvinit one (scripts/lab/qemu/prepare.sh build
# debian-sysv), as root over ssh: "install" while systemd still runs, then — after the host
# reboots the guest — "verify" under the new PID 1. The inittab and rc.local suites and W1-7's
# Debian half need a guest whose init really is sysvinit.
set -eu
D=/var/lib/machman-lab
mkdir -p "$D"
export DEBIAN_FRONTEND=noninteractive
case "${1:-}" in
install)
	exec >"$D/prepare-sysv.log" 2>&1
	set -x
	apt-get update -qq
	# Networking without systemd-networkd: ifupdown and a DHCP client on every virtio NIC
	# name the QEMU and VZ slots give (unused stanzas are inert).
	apt-get install -y -qq --no-install-recommends ifupdown isc-dhcp-client
	# systemd-sysv provides "init" and is protected: name its removal outright.
	apt-get install -y -qq --allow-remove-essential sysvinit-core initscripts \
		orphan-sysvinit-scripts systemd-sysv-
	{
		printf 'auto lo\niface lo inet loopback\n'
		for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
			printf '\nallow-hotplug enp0s%s\niface enp0s%s inet dhcp\n' "$n" "$n"
		done
	} > /etc/network/interfaces
	grep -q '^L2:' /etc/inittab \
		|| echo 'L2:2345:respawn:/sbin/getty -L hvc2 115200 vt100' >> /etc/inittab
	apt-get clean
	touch "$D/sysv-installed"
	;;
verify)
	exec >"$D/prepare-sysv-verify.log" 2>&1
	set -x
	pid1="$(readlink /proc/1/exe)"
	case "$pid1" in */sbin/init) ;; *) echo "PID 1 is $pid1"; exit 1 ;; esac
	[ ! -e /run/systemd/system ] || { echo "/run/systemd/system exists"; exit 1; }
	fstrim -av || true
	{
		echo "debian $(cat /etc/debian_version)"
		echo "pid1 $(ps -o comm= -p 1) ($pid1)"
		echo "uname $(uname -r)"
		dpkg-query -W -f '${Package} ${Version}\n' | sort
	} > "$D/manifest"
	touch "$D/prepared"
	;;
*)
	echo "usage: prepare-sysv.sh install|verify" >&2
	exit 64
	;;
esac
