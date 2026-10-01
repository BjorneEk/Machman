#!/bin/sh
# Container regression harness for the ASSEMBLED Guest Setup script: the invariants behind
# its fixes, checked per distro, each one a named RESULT_<NAME>=pass line.
#
#   scripts/guest-regress/run.sh [--pull] [--shell <sh|ksh>] [distro…]   every distro if none
#   scripts/guest-regress/run.sh --list                                  distros and suites
#
# A dev tool, never a gate: scripts/test.sh does not run it, and nothing else needs Docker.
# It assembles the script fresh from this checkout, builds one cached image per distro
# (machman-regress-<distro>; --pull refreshes the bases) and runs every suite in its own
# fresh container over its own copy of the payload, so no suite sees another's leftovers.
# Exits 69 without Docker, 64 on a usage error, 1 on any failed or missing check.
#
# Images are native (arm64 on Apple silicon) except devuan, which upstream ships for amd64
# only and runs emulated (about 25 s). arch is the community menci/archlinuxarm image (the
# official one is amd64-only). --shell ksh on alpine runs the script under loksh, OpenBSD's
# ksh lineage; the suites name every check they expect on their "# CHECKS:" lines.
set -u
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../.." && pwd)"

ALL="debian ubuntu fedora leap tumbleweed arch alpine void devuan"
APT='apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq'
APT="$APT --no-install-recommends"
ZYPPER='zypper -n -q install'

# distro <name> → IMAGE, PLATFORM (empty: native), PREP (run once, cached in the image) and
# SUITES; 1 for an unknown name.
distro() {
	PLATFORM=""
	case "$1" in
	debian)
		IMAGE=debian:12
		PREP="$APT grub2-common openssh-client iproute2 initscripts procps sshfs"
		SUITES="systemd rclocal files grub uninstall nixos" ;;
	ubuntu)
		IMAGE=ubuntu:24.04
		PREP="$APT grub2-common openssh-client iproute2 sshfs"
		SUITES="systemd files grub" ;;
	fedora)
		# grub2-tools without grubby: the /etc/default/grub path (BLS needs a real boot).
		IMAGE=fedora:42
		PREP="dnf install -y -q grub2-tools openssh-clients iproute util-linux procps-ng"
		PREP="$PREP fuse-sshfs"
		SUITES="systemd files grub" ;;
	leap)
		IMAGE=opensuse/leap:15.6
		PREP="$ZYPPER grub2 openssh-clients iproute2 util-linux-systemd sshfs"
		SUITES="systemd files grub" ;;
	tumbleweed)
		IMAGE=opensuse/tumbleweed:latest
		PREP="$ZYPPER gawk diffutils grub2 openssh-clients iproute2 util-linux-systemd sshfs"
		SUITES="systemd files grub" ;;
	arch)
		# Landlock is not permitted in Docker: pacman runs without its sandbox.
		IMAGE=menci/archlinuxarm:latest
		PREP="pacman -Sy --noconfirm --disable-sandbox grub openssh iproute2 diffutils sshfs"
		SUITES="systemd files grub" ;;
	alpine)
		IMAGE=alpine:3.24
		PREP="apk add -q openrc openssh-keygen sshfs util-linux-misc loksh"
		SUITES="openrc console files uninstall" ;;
	void)
		IMAGE=ghcr.io/void-linux/void-glibc:latest
		PREP="xbps-install -Syu xbps && xbps-install -Sy runit-void shadow openssh iproute2"
		PREP="$PREP util-linux fuse-sshfs diffutils findutils"
		PREP="$PREP && ln -sfn default /etc/runit/runsvdir/current"
		PREP="$PREP && ln -sfn /etc/runit/runsvdir/current /var/service"
		SUITES="rclocal files" ;;
	devuan)
		IMAGE=devuan/devuan:excalibur
		PLATFORM=linux/amd64
		PREP="$APT openssh-client iproute2 initscripts procps sshfs"
		SUITES="rclocal files uninstall" ;;
	*)
		return 1 ;;
	esac
	return 0
}

usage() {
	echo "usage: run.sh [--pull] [--shell <sh|ksh>] [distro…] | run.sh --list" >&2
	exit 64
}

PULL=""
SHELL_UNDER_TEST=sh
while [ $# -gt 0 ]; do
	case "$1" in
	--list)
		for n in $ALL; do
			distro "$n"
			printf '%-11s %-38s %-12s %s\n' "$n" "$IMAGE" "${PLATFORM:-native}" "$SUITES"
		done
		exit 0
		;;
	--pull) PULL=--pull; shift ;;
	--shell) [ $# -ge 2 ] || usage; SHELL_UNDER_TEST="$2"; shift 2 ;;
	--) shift; break ;;
	-*) usage ;;
	*) break ;;
	esac
done
NAMES="${*:-$ALL}"
for n in $NAMES; do
	distro "$n" || { echo "unknown distro: $n (see --list)" >&2; exit 64; }
done
command -v docker >/dev/null 2>&1 || { echo "Docker is not installed" >&2; exit 69; }

sh "$ROOT/MachmanKit/Sources/MachmanCore/GuestScripts/assemble.sh" >/dev/null \
	|| { echo "assemble failed" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The payload Machman would serve, staged once and copied per suite.
M="machman-regres000001"
P="$TMP/payload"
mkdir -p "$P/GuestSetup" "$P/GuestReport" "$P/regress"
cp "$ROOT/MachmanKit/Sources/MachmanCore/GuestScripts/dist/install.sh" "$P/GuestSetup/"
cat > "$P/GuestSetup/machman.env" <<EOF
VM_NAME='regression-vm'
MARKER='$M'
REPORT_DIR_NAME='GuestReport'
MOUNT_ROOT='/mnt/machman/mounts'
SHARE_ROOT='/mnt/machman/share'
SHARE_TAG='host-share'
SHARE_HOST_PATH='/Users/g/App Support/regression/share'
BOOT_MODE='efi'
CONSOLE_COUNT='2'
UART_COUNT='0'
HOST_USER='gustaf'
HOST_NAME='Mac'
HOST_LOCAL='mac.local'
EOF
printf 'ssh-ed25519 AAAA_REGRESSION_BLOB %s regression-vm\n' "$M" > "$P/GuestSetup/host_key.pub"
printf 'sshfs\tprojects\t/Users/g/Projects\nsshfs\tdocs\t/Users/g/My Docs\n' \
	> "$P/GuestSetup/mounts.list"
cp "$HERE/lib.sh" "$HERE"/suites/*.sh "$P/regress/"
# A read-only stand-in for /nix/store, mounted into every container (the nixos suite links
# /etc/fstab and /etc/systemd/system into it, as NixOS does).
mkdir -p "$TMP/store/systemd-system"
: > "$TMP/store/fstab"

FAILED=0
TOTAL=0
for n in $NAMES; do
	distro "$n"
	tag="machman-regress-$n"
	start="$(date +%s)"
	# shellcheck disable=SC2086
	printf 'FROM %s\nRUN %s\n' "$IMAGE" "$PREP" \
		| docker build -q $PULL ${PLATFORM:+--platform "$PLATFORM"} -t "$tag" - >/dev/null \
		|| { echo "== $n: image build failed"; FAILED=1; continue; }
	for s in $SUITES; do
		stage="$TMP/$n-$s"
		cp -R "$P" "$stage"
		out="$TMP/$n-$s.out"
		docker run --rm ${PLATFORM:+--platform "$PLATFORM"} \
			-v "$stage:/mnt/machman/share" -v "$TMP/store:/nix/store:ro" \
			-e "REGRESS_DISTRO=$n" -e "REGRESS_SHELL=$SHELL_UNDER_TEST" "$tag" \
			sh "/mnt/machman/share/regress/$s.sh" > "$out" 2>&1
		expected="$(sed -n 's/^# CHECKS: //p' "$HERE/suites/$s.sh" | tr '\n' ' ')"
		bad=""
		for c in $expected; do
			TOTAL=$((TOTAL + 1))
			case "$(grep "^RESULT_$c=" "$out" | tail -n 1)" in
			"RESULT_$c=pass") ;;
			"") bad="$bad MISSING:$c" ;;
			*) bad="$bad FAILED:$c" ;;
			esac
		done
		if [ -n "$bad" ]; then
			FAILED=1
			echo "== $n/$s:$bad"
			grep -v '^RESULT_' "$out" | head -n 20 | sed 's/^/   /'
		else
			echo "== $n/$s: $(printf '%s' "$expected" | wc -w | tr -d ' ') checks pass"
		fi
	done
	echo "   ($n: $(( $(date +%s) - start ))s)"
done
[ "$FAILED" -eq 0 ] && echo "guest-regress: all $TOTAL checks pass"
exit "$FAILED"
