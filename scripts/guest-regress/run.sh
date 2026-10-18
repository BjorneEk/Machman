#!/bin/sh
# Regression harness for the ASSEMBLED Guest Setup script: the invariants behind its fixes,
# checked per distro, each one a named RESULT_<NAME>=pass line.
#
#   scripts/guest-regress/run.sh [--pull] [--shell <sh|ksh>] [distro…]   every distro if none
#   scripts/guest-regress/run.sh --list                                  distros and suites
#   scripts/guest-regress/run.sh --backend qemu [--results <tsv>] [--image <raw>] [--keep]
#                                [--jobs 1|2] [--suites '<suite>…'] [--shell <sh|ksh>] [distro…]
#   scripts/guest-regress/run.sh --backend vz [--results <tsv>] [--suites '<suite>…'] [--keep]
#                                [debian|debian-sysv…]
#   scripts/guest-regress/run.sh --backend qemu|vz --list
#   scripts/guest-regress/run.sh --evaluate <suite> <run|boot> <output>  one output's TSV rows
#   scripts/guest-regress/run.sh --stage <dir>     assemble and stage the payload into <dir>/payload
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
#
# --backend qemu runs the suites inside real guests instead: the lab's prepared images
# (scripts/lab/qemu/prepare.sh) under its headless QEMU runner, one fresh clone per suite,
# restricted networking, the payload copied in over ssh — inside a lab run: scripts/lab.sh's
# (MACHMAN_LAB_RUN, e.g. from MachmanLabTests), else one of its own that holds the lab slot
# (scripts/lab/qemu/lab-session.sh; --keep keeps its root). A real init is there, so lib.sh's
# fake_systemd stands aside (REGRESS_BACKEND). The VM table is its own: nixos is a container
# stand-in (an /etc/fstab linked into a read-only /nix/store) and stays docker-only, and the
# inittab and rc.local suites need the sysvinit Debian. --backend vz runs the Debian suites in
# Machman's own VZ guests: MachmanLabTests' GuestRegressVZTests under scripts/lab.sh --guests
# (its agent, slot and audits; the distros, --suites and --results pass through as
# MACHMAN_LAB_REGRESS_*; a --results file inside the repo would trip lab.sh's worktree
# audit). A suite with "# BOOT-CHECKS:" lines (grub, automount, console, rclocal) ends its VM
# run with a tail left installed; the harness reboots the guest (under VZ: powers it off and
# starts it again) and runs it again with REGRESS_PHASE=boot for its after-boot checks
# (docker reads only "# CHECKS:" and never reboots). --suites narrows each distro's VM suites
# to those listed. --results appends one TSV row per check: distro, suite, phase, check,
# pass|fail|missing. Exits 69 without QEMU or without a prepared image.
set -u
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../.." && pwd)"

ALL="debian ubuntu fedora fedora-bls leap tumbleweed arch alpine void devuan"
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
		SUITES="systemd rclocal files grub uninstall nixos automount console" ;;
	ubuntu)
		IMAGE=ubuntu:24.04
		PREP="$APT grub2-common openssh-client iproute2 sshfs"
		SUITES="systemd files grub automount" ;;
	fedora)
		# grub2-tools without grubby: the /etc/default/grub path (BLS needs a real boot).
		IMAGE=fedora:42
		PREP="dnf install -y -q grub2-tools openssh-clients iproute util-linux procps-ng"
		PREP="$PREP fuse-sshfs"
		SUITES="systemd files grub automount" ;;
	fedora-bls)
		# The same with grubby: the kernel console's BLS path, over a fabricated entry.
		IMAGE=fedora:42
		PREP="dnf install -y -q grub2-tools openssh-clients iproute util-linux procps-ng"
		PREP="$PREP fuse-sshfs grubby"
		SUITES="grubby" ;;
	leap)
		IMAGE=opensuse/leap:15.6
		PREP="$ZYPPER grub2 openssh-clients iproute2 util-linux-systemd sshfs"
		SUITES="systemd files grub automount" ;;
	tumbleweed)
		IMAGE=opensuse/tumbleweed:latest
		PREP="$ZYPPER gawk diffutils grub2 openssh-clients iproute2 util-linux-systemd sshfs"
		SUITES="systemd files grub automount" ;;
	arch)
		# Landlock is not permitted in Docker: pacman runs without its sandbox.
		IMAGE=menci/archlinuxarm:latest
		PREP="pacman -Sy --noconfirm --disable-sandbox grub openssh iproute2 diffutils sshfs"
		SUITES="systemd files grub automount" ;;
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
		SUITES="rclocal files runit" ;;
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

VM_ALL="debian debian-sysv freebsd14 freebsd15"

# vm_distro <name> → VM_GUEST (the lab's prepared image), VM_OS (its scripts/lab/guests dir)
# and SUITES for the VM backends; 1 for an unknown name. A suite that cannot apply in a VM is
# left out here with its reason, never edited to pass.
vm_distro() {
	case "$1" in
	debian)
		# console and rclocal need an inittab / rc.local init: debian-sysv runs them.
		VM_GUEST=debian VM_OS=debian
		SUITES="smoke systemd grub files uninstall automount" ;;
	debian-sysv)
		# systemd, grub and automount assume systemd as PID 1: debian runs them.
		VM_GUEST=debian-sysv VM_OS=debian
		SUITES="smoke console rclocal files uninstall" ;;
	freebsd14|freebsd15)
		# The Linux suites (systemd, grub, inittab, fstab automounts) do not apply.
		VM_GUEST="$1" VM_OS=freebsd
		SUITES="smoke" ;;
	*)
		return 1 ;;
	esac
	return 0
}

# pick_suites: SUITES (of distro $n) narrowed to --suites; a suite it does not run is an error.
pick_suites() {
	[ -n "$ONLY_SUITES" ] || return 0
	_picked=""
	for _w in $ONLY_SUITES; do
		case " $SUITES " in
		*" $_w "*) _picked="$_picked $_w" ;;
		*) echo "$n does not run suite $_w (see --backend $BACKEND --list)" >&2; exit 64 ;;
		esac
	done
	SUITES="${_picked# }"
}

usage() {
	echo "usage: run.sh [--pull] [--shell <sh|ksh>] [distro…] | run.sh --list" >&2
	echo "       run.sh --backend qemu|vz [--results <tsv>] [--image <raw>] [--keep]" \
		"[--jobs 1|2] [--suites '<suite>…'] [distro…]" >&2
	echo "       run.sh --evaluate <suite> <run|boot> <output>" >&2
	exit 64
}

# evaluate <distro> <suite> <phase> <output>: the suite's named checks for that phase (its
# "# CHECKS:" lines for run, "# BOOT-CHECKS:" for boot) against the output's RESULT_ lines.
# Sets EXPECTED and BAD, counts TOTAL, appends a TSV row per check to $RESULTS when set. The
# one rule every backend uses.
evaluate() {
	EXPECTED="$(sed -n "s/^# $(phase_tag "$3"): //p" "$HERE/suites/$2.sh" | tr '\n' ' ')"
	BAD=""
	for c in $EXPECTED; do
		TOTAL=$((TOTAL + 1))
		case "$(grep "^RESULT_$c=" "$4" | tail -n 1)" in
		"RESULT_$c=pass") st=pass ;;
		"") BAD="$BAD MISSING:$c"; st=missing ;;
		*) BAD="$BAD FAILED:$c"; st=fail ;;
		esac
		[ -z "$RESULTS" ] || printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$c" "$st" >> "$RESULTS"
	done
}

phase_tag() {
	case "$1" in
	run) echo CHECKS ;;
	boot) echo BOOT-CHECKS ;;
	*) echo "unknown phase: $1" >&2; exit 64 ;;
	esac
}

# report <label> <output>: the per-suite line every backend prints after evaluate.
report() {
	if [ -n "$BAD" ]; then
		FAILED=1
		echo "== $1:$BAD"
		grep -v '^RESULT_' "$2" | head -n 20 | sed 's/^/   /'
	else
		echo "== $1: $(printf '%s' "$EXPECTED" | wc -w | tr -d ' ') checks pass"
	fi
}

# stage_payload <install.sh> <dir>: the payload Machman would serve, staged once and copied
# per suite.
stage_payload() {
	M="machman-regres000001"
	P="$2"
	mkdir -p "$P/GuestSetup" "$P/GuestReport" "$P/regress"
	cp "$1" "$P/GuestSetup/"
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
	# The file-edit helpers on their own (and the output they report through), for suites
	# that drive them directly.
	cp "$ROOT/MachmanKit/Sources/MachmanCore/GuestScripts/setup/05-lib.sh" \
		"$ROOT/MachmanKit/Sources/MachmanCore/GuestScripts/setup/07-files.sh" "$P/regress/"
}

backend_docker() {
	NAMES="${*:-$ALL}"
	for n in $NAMES; do
		distro "$n" || { echo "unknown distro: $n (see --list)" >&2; exit 64; }
	done
	command -v docker >/dev/null 2>&1 || { echo "Docker is not installed" >&2; exit 69; }

	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	sh "$ROOT/MachmanKit/Sources/MachmanCore/GuestScripts/assemble.sh" "$TMP/install.sh" \
		>/dev/null || { echo "assemble failed" >&2; exit 1; }
	stage_payload "$TMP/install.sh" "$TMP/payload"
	# A read-only stand-in for /nix/store, mounted into every container (the nixos suite links
	# /etc/fstab and /etc/systemd/system into it, as NixOS does).
	mkdir -p "$TMP/store/systemd-system"
	: > "$TMP/store/fstab"

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
			cp -R "$TMP/payload" "$stage"
			out="$TMP/$n-$s.out"
			docker run --rm ${PLATFORM:+--platform "$PLATFORM"} \
				-v "$stage:/mnt/machman/share" -v "$TMP/store:/nix/store:ro" \
				-e "REGRESS_DISTRO=$n" -e "REGRESS_SHELL=$SHELL_UNDER_TEST" "$tag" \
				sh "/mnt/machman/share/regress/$s.sh" > "$out" 2>&1
			evaluate "$n" "$s" run "$out"
			report "$n/$s" "$out"
		done
		echo "   ($n: $(( $(date +%s) - start ))s)"
	done
}

# --- the qemu backend -----------------------------------------------------------------------

LAB="$ROOT/scripts/lab"

# in_lab_run: a live lab run is ours to use — MACHMAN_LAB_RUN names a /tmp/mml.<token> root
# whose owner (lab.sh or a lab session) is alive and holds the lab slot.
in_lab_run() {
	case "${MACHMAN_LAB_RUN:-}" in /tmp/mml.*) ;; *) return 1 ;; esac
	[ -d "$MACHMAN_LAB_RUN" ] && [ -f "$MACHMAN_LAB_RUN/.owner" ] || return 1
	kill -0 "$(head -n 1 "$MACHMAN_LAB_RUN/.owner" | tr -cd '0-9')" 2>/dev/null
}

# vm_ssh <guest dir> <command>: the guest's user, its baked key, the lab's ssh options.
vm_ssh() {
	(
		# shellcheck source=/dev/null
		. "$1/guest.env"
		LAB_KNOWN_HOSTS="$1/known_hosts" lab_ssh "$TMP" "$GUEST_KEY" \
			"$GUEST_USER@127.0.0.1" "$GUEST_PORT" "$2"
	)
}

# with_timeout <seconds> <command…>: a hung guest command must not hang the harness.
with_timeout() {
	perl -e 'alarm shift; exec @ARGV or exit 127' "$@"
}

# vm_suite <distro> <suite>: one suite in a fresh guest; leaves <distro>-<suite>.run.out and,
# for a suite with boot checks, <distro>-<suite>.boot.out (the run's tail installed, the guest
# rebooted, the suite run again for its boot block).
vm_suite() {
	vm_distro "$1"
	n="$1" s="$2"
	name="$(printf 'r-%s-%s' "$n" "$s" | cut -c1-32)"
	stage="$TMP/$n-$s"
	out="$TMP/$n-$s.run.out"
	cp -R "$TMP/payload" "$stage"
	root=""
	[ "$VM_OS" = freebsd ] && root="doas "
	echo "$name" >> "$TMP/guests"
	if ! d="$("$LAB/guests/$VM_OS/guest.sh" boot "$VM_GUEST" --run "$RUN" --name "$name" \
		--owner $$ ${VM_IMAGE:+--image "$VM_IMAGE"} 2>"$TMP/$n-$s.boot.err")"; then
		cat "$TMP/$n-$s.boot.err" > "$out"
		return 0
	fi
	COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$stage" -cf - . \
		| vm_ssh "$d" "${root}sh -c 'rm -rf /mnt/machman/share && mkdir -p /mnt/machman/share \
&& tar -xf - --no-same-owner -C /mnt/machman/share'" > "$out" 2>&1
	vm_run "$d" run >> "$out" 2>&1
	if has_boot_checks "$s"; then
		vm_reboot "$d" > "$TMP/$n-$s.boot.out" 2>&1 \
			&& vm_run "$d" boot >> "$TMP/$n-$s.boot.out" 2>&1
	fi
	"$LAB/qemu/run.sh" stop --run "$RUN" --name "$name" --timeout 0
	rm -f "$d/disk.raw"
}

# stop_guests: this harness's guests, never another's in a shared lab run.
stop_guests() {
	[ -f "$TMP/guests" ] || return 0
	while IFS= read -r g; do
		"$LAB/qemu/run.sh" stop --run "$RUN" --name "$g" --timeout 0 >/dev/null 2>&1
		rm -f "$RUN/qemu/$g/disk.raw"
	done < "$TMP/guests"
}

has_boot_checks() { grep -q '^# BOOT-CHECKS: ' "$HERE/suites/$1.sh"; }

# vm_reboot <guest dir>: reboot, wait for ssh to drop (60 s) and come back (180 s), put the
# guest's default route back on the lab gateway.
vm_reboot() {
	vm_ssh "$1" "${root}sh -c 'nohup sh -c \"sleep 1; reboot\" >/dev/null 2>&1 </dev/null &'"
	end=$(( $(date +%s) + 60 ))
	while vm_ssh "$1" true </dev/null >/dev/null 2>&1; do
		[ "$(date +%s)" -lt "$end" ] || { echo "reboot: the guest did not go down"; return 1; }
		sleep 2
	done
	t0="$(date +%s)"
	end=$(( t0 + 180 ))
	until vm_ssh "$1" true </dev/null >/dev/null 2>&1; do
		[ "$(date +%s)" -lt "$end" ] || { echo "reboot: no ssh within 180 s"; return 1; }
		sleep 2
	done
	echo "reboot: ssh back after $(( $(date +%s) - t0 )) s"
	vm_ssh "$1" "$("$LAB/guests/$VM_OS/guest.sh" lab-route)" </dev/null
}

# vm_run <guest dir> <phase>: the suite ($n, $s) as root in the guest, 20 minutes at most.
vm_run() {
	with_timeout 1200 sh "$HERE/run.sh" --vm-ssh "$1" "${root}env REGRESS_DISTRO=$n \
REGRESS_SHELL=$SHELL_UNDER_TEST REGRESS_BACKEND=$BACKEND REGRESS_PHASE=$2 \
sh /mnt/machman/share/regress/$s.sh"
}

backend_qemu() {
	NAMES="${*:-$VM_ALL}"
	for n in $NAMES; do
		vm_distro "$n" || { echo "unknown VM distro: $n (see --backend qemu --list)" >&2; exit 64; }
		pick_suites
	done
	# shellcheck disable=SC2086
	if [ -n "$VM_IMAGE" ] && [ "$(printf '%s\n' $NAMES | wc -l | tr -d ' ')" != 1 ]; then
		echo "--image takes exactly one distro" >&2
		exit 64
	fi
	command -v qemu-system-aarch64 >/dev/null 2>&1 \
		|| { echo "QEMU is not installed (qemu-system-aarch64)" >&2; exit 69; }
	if [ -z "$VM_IMAGE" ]; then
		for n in $NAMES; do
			vm_distro "$n"
			"$LAB/qemu/prepare.sh" path "$VM_GUEST" --no-build >/dev/null || exit 69
		done
	fi
	# Guests boot inside a lab run (the slot, scripts/lib/sandbox.sh): lab.sh's, or our own.
	if ! in_lab_run; then
		exec bash "$LAB/qemu/lab-session.sh" ${KEEP:+--keep} sh "$0" --backend qemu \
			${RESULTS:+--results "$RESULTS"} ${VM_IMAGE:+--image "$VM_IMAGE"} --jobs "$JOBS" \
			${ONLY_SUITES:+--suites "$ONLY_SUITES"} --shell "$SHELL_UNDER_TEST" "$@"
	fi
	RUN="$MACHMAN_LAB_RUN"
	TMP="$RUN/regress.$$"
	mkdir -p "$TMP"
	trap 'stop_guests' EXIT
	trap 'exit 130' INT TERM HUP
	export TMP RUN
	sh "$ROOT/MachmanKit/Sources/MachmanCore/GuestScripts/assemble.sh" "$TMP/install.sh" \
		>/dev/null || { echo "assemble failed" >&2; exit 1; }
	stage_payload "$TMP/install.sh" "$TMP/payload"

	# JOBS suites at a time, each in its own guest; then every output is evaluated in order.
	jobs_list=""
	for n in $NAMES; do
		vm_distro "$n"
		pick_suites
		for s in $SUITES; do jobs_list="$jobs_list $n:$s"; done
	done
	start="$(date +%s)"
	batch=""
	for j in $jobs_list; do
		batch="$batch $j"
		# shellcheck disable=SC2086
		[ "$(printf '%s\n' $batch | wc -l | tr -d ' ')" -lt "$JOBS" ] && continue
		# shellcheck disable=SC2086
		run_batch $batch
		batch=""
	done
	# shellcheck disable=SC2086
	[ -z "$batch" ] || run_batch $batch
	for j in $jobs_list; do
		n="${j%%:*}" s="${j#*:}"
		evaluate "$n" "$s" run "$TMP/$n-$s.run.out"
		report "$n/$s" "$TMP/$n-$s.run.out"
		has_boot_checks "$s" || continue
		[ -f "$TMP/$n-$s.boot.out" ] || : > "$TMP/$n-$s.boot.out"
		evaluate "$n" "$s" boot "$TMP/$n-$s.boot.out"
		report "$n/$s after boot" "$TMP/$n-$s.boot.out"
	done
	echo "   (qemu: $(( $(date +%s) - start ))s; outputs in $TMP)"
}

run_batch() { # <distro:suite>…: in parallel, each in its own guest
	for j in "$@"; do
		vm_suite "${j%%:*}" "${j#*:}" &
	done
	wait
}

BACKEND=docker
RESULTS=""
VM_IMAGE=""
KEEP=""
JOBS=1
ONLY_SUITES=""
LIST=""
PULL=""
SHELL_UNDER_TEST=sh
while [ $# -gt 0 ]; do
	case "$1" in
	--list) LIST=1; shift ;;
	--pull) PULL=--pull; shift ;;
	--shell) [ $# -ge 2 ] || usage; SHELL_UNDER_TEST="$2"; shift 2 ;;
	--backend) [ $# -ge 2 ] || usage; BACKEND="$2"; shift 2 ;;
	--results) [ $# -ge 2 ] || usage; RESULTS="$2"; shift 2 ;;
	--image) [ $# -ge 2 ] || usage; VM_IMAGE="$2"; shift 2 ;;
	--keep) KEEP=1; shift ;;
	--jobs) [ $# -ge 2 ] || usage; JOBS="$2"; shift 2 ;;
	--suites) [ $# -ge 2 ] || usage; ONLY_SUITES="$2"; shift 2 ;;
	--stage)
		# The payload every VM backend serves, for GuestRegressVZ (it tars it onto a disk).
		[ $# -eq 2 ] || usage
		mkdir -p "$2/.assembled" || exit 1
		sh "$ROOT/MachmanKit/Sources/MachmanCore/GuestScripts/assemble.sh" \
			"$2/.assembled/install.sh" >/dev/null || { echo "assemble failed" >&2; exit 1; }
		rm -rf "$2/payload"
		stage_payload "$2/.assembled/install.sh" "$2/payload"
		rm -rf "$2/.assembled"
		exit 0
		;;
	--evaluate)
		[ $# -eq 4 ] || usage
		RESULTS=/dev/stdout TOTAL=0
		[ -f "$HERE/suites/$2.sh" ] || { echo "no suite $2" >&2; exit 64; }
		evaluate "${REGRESS_DISTRO:--}" "$2" "$3" "$4"
		[ -z "$BAD" ]
		exit $?
		;;
	--vm-ssh)
		# Internal (vm_run under with_timeout): ssh into a booted guest.
		# shellcheck source=../lab/sshd/ssh-opts.sh
		. "$ROOT/scripts/lab/sshd/ssh-opts.sh"
		vm_ssh "$2" "$3"
		exit $?
		;;
	--) shift; break ;;
	-*) usage ;;
	*) break ;;
	esac
done
case "$BACKEND" in docker|qemu|vz) ;; *) usage ;; esac
case "$JOBS" in 1|2) ;; *) echo "--jobs is 1 or 2 (two lab guests at most)" >&2; exit 64 ;; esac
if [ -n "$LIST" ]; then
	if [ "$BACKEND" = docker ]; then
		for n in $ALL; do
			distro "$n"
			printf '%-11s %-38s %-12s %s\n' "$n" "$IMAGE" "${PLATFORM:-native}" "$SUITES"
		done
	else
		for n in $VM_ALL; do
			vm_distro "$n"
			printf '%-12s %-12s %s\n' "$n" "$VM_GUEST" "$SUITES"
		done
	fi
	exit 0
fi
[ -z "$RESULTS" ] || : > "$RESULTS"

FAILED=0
TOTAL=0
case "$BACKEND" in
docker) backend_docker "$@" ;;
qemu)
	# shellcheck source=../lab/sshd/ssh-opts.sh
	. "$LAB/sshd/ssh-opts.sh"
	backend_qemu "$@" ;;
vz)
	for n in ${*:-debian debian-sysv}; do
		vm_distro "$n" || { echo "unknown VM distro: $n (see --backend vz --list)" >&2; exit 64; }
		[ "$VM_OS" = debian ] \
			|| { echo "the vz backend runs debian and debian-sysv, not $n" >&2; exit 64; }
		pick_suites
	done
	case "$RESULTS" in ''|/*) ;; *) RESULTS="$(pwd)/$RESULTS" ;; esac
	MACHMAN_LAB_REGRESS_DISTROS="${*:-debian debian-sysv}" \
		MACHMAN_LAB_REGRESS_SUITES="$ONLY_SUITES" MACHMAN_LAB_REGRESS_RESULTS="$RESULTS" \
		exec bash "$ROOT/scripts/lab.sh" --guests --filter GuestRegressVZTests ${KEEP:+--keep} ;;
esac
[ "$FAILED" -eq 0 ] && echo "guest-regress: all $TOTAL checks pass"
exit "$FAILED"
