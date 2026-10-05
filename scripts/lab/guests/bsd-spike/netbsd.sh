#!/bin/bash
# Spike (r3t, time-boxed; not a lab guest — T14): does the stock NetBSD arm64 image boot
# unattended under QEMU with a serial console, and give a root shell, sshd and a virtio
# console? Writes the run's answer to <run>/netbsd/answer.txt.
#
#   netbsd.sh [--source <arm64.img.gz>] [--cache <dir>] [--run <root>] [--keep]
#
# Image: <cache>/spike/netbsd-11.0-arm64.raw, made once from --source (or the fetch.sh fixture
# netbsd-11.0-arm64.img, recipe gz) by a sparse gunzip. Each run boots a clone extended to
# 4 GiB (the image grows its root at first boot): serial console, one virtconsole,
# restricted networking, ssh forward. ACPI first; on no login prompt, again with acpi=off.
#
# ANSWER (2026-10-05, NetBSD 11.0 evbarm-aarch64 arm64.img, QEMU 10.0.3 HVF, edk2): WORKS.
#   Root shell on the serial console 31 s after start, with ACPI (no acpi=off needed), root
#   without a password; viocon0 attaches (ttyVI00..ttyVI30 exist); sshd on + a key over the
#   console, then root over the hostfwd works. Whole run 37 s. Recipe: gunzip (sparse) the
#   stock arm64.img.gz, clone, grow to 4 GiB, boot. Image gz sha256 12e089f1…, the unpacked
#   arm64.img matches the release MD5 62df032d….
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../qemu/common.sh
. "$HERE/../../qemu/common.sh"
# shellcheck source=../../sshd/ssh-opts.sh
. "$LAB_DIR/sshd/ssh-opts.sh"

VERSION=11.0
SOURCE="" RUN="" KEEP=""
while [ $# -gt 0 ]; do
	case "$1" in
	--source) SOURCE="${2:-}"; shift 2 ;;
	--cache) MACHMAN_LAB_CACHE="${2:-}"; export MACHMAN_LAB_CACHE; shift 2 ;;
	--run) RUN="${2:-}"; shift 2 ;;
	--keep) KEEP=1; shift ;;
	*) sed -n '6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
	esac
done
PY="$(lab_tool python3)"
CON="$LAB_QEMU_DIR/console.py"
img="$(lab_cache_dir)/spike/netbsd-$VERSION-arm64.raw"
if [ ! -f "$img" ]; then
	[ -n "$SOURCE" ] || SOURCE="$(lab_cache_dir)/fixtures/netbsd-$VERSION-arm64.img"
	[ -f "$SOURCE" ] || lab_die 69 "no NetBSD image: pass --source <arm64.img.gz>."
	mkdir -p "$(dirname "$img")"
	case "$SOURCE" in
	*.gz) gzip -dc "$SOURCE" | dd of="$img.part" bs=1m conv=sparse 2>/dev/null ;;
	*) cp -c "$SOURCE" "$img.part" ;;
	esac || lab_die 1 "could not unpack $SOURCE."
	chmod 444 "$img.part"
	mv "$img.part" "$img"
fi
if [ -z "$RUN" ]; then
	RUN="$(lab_new_root)"
	OWN_RUN="$RUN"
else
	OWN_RUN=""
fi
lab_check_run_root "$RUN"
trap '"$LAB_QEMU_DIR/run.sh" sweep "$RUN" >/dev/null 2>&1
	[ -n "$OWN_RUN" ] && [ -z "$KEEP" ] && rm -rf "$OWN_RUN"' EXIT
out="$RUN/netbsd"
mkdir -p "$out"
ssh-keygen -q -t ed25519 -N '' -C lab-netbsd -f "$out/id_ed25519" </dev/null
answer() { echo "$*" | tee -a "$out/answer.txt"; }

try_boot() { # <name> [--no-acpi]: 0 once root has a shell on the serial console
	local name="$1" d t0
	shift
	d="$RUN/qemu/$name"
	mkdir -p "$d"
	cp -c "$img" "$d/disk.raw" && chmod 644 "$d/disk.raw"
	dd if=/dev/zero of="$d/disk.raw" bs=1 count=0 seek=$((4 * 1073741824)) 2>/dev/null
	t0=$SECONDS
	"$LAB_QEMU_DIR/run.sh" start --run "$RUN" --name "$name" --disk "$d/disk.raw" \
		--consoles 1 --ssh-forward --cpus 2 --mem 1024 --owner $$ "$@" >/dev/null || return 1
	if "$PY" "$CON" "$d/serial.sock" --transcript "$d/serial.transcript" login --user root \
		--nudge 20 --timeout 600; then
		answer "netbsd: root shell on the serial console after $((SECONDS - t0)) s" \
			"(${*:-with ACPI})"
		return 0
	fi
	answer "netbsd: no root shell on the serial console within 600 s (${*:-with ACPI}); tail:"
	tr -d '\r' < "$d/serial.log" | tail -n 8 | sed 's/^/    /' | tee -a "$out/answer.txt"
	"$LAB_QEMU_DIR/run.sh" stop --run "$RUN" --name "$name" --timeout 0
	return 1
}

name=netbsd
if ! try_boot netbsd; then
	name=netbsd-noacpi
	try_boot netbsd-noacpi --no-acpi || { answer "netbsd: BLOCKED (no console login)"; exit 1; }
fi
d="$RUN/qemu/$name"
run() { "$PY" "$CON" "$d/serial.sock" --transcript "$d/serial.transcript" run --timeout "$1" \
	-- "$2"; }
answer "uname: $(run 30 'uname -a' | tr -d '\r')"
VIO='dmesg | grep -i viocon | head -n 3; ls /dev | grep -i -E "^ttyVI|^viocon" | head -n 4'
answer "viocon: $(run 30 "$VIO" | tr -d '\r' | tr '\n' ';')"
pub="$(cat "$out/id_ed25519.pub")"
run 120 "mkdir -p -m 700 /root/.ssh && echo '$pub' > /root/.ssh/authorized_keys \
&& printf '10.0.2.2 lab-slirp-host\n10.0.2.100 lab-gateway\n' >> /etc/hosts \
&& echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config \
&& echo sshd=YES >> /etc/rc.conf && /etc/rc.d/sshd start" >/dev/null
port="$(cat "$d/ssh.port")"
ok=""
end=$((SECONDS + 120))
while [ "$SECONDS" -lt "$end" ]; do
	if r="$(LAB_KNOWN_HOSTS="$out/known_hosts" lab_ssh "$RUN" "$out/id_ed25519" \
		root@127.0.0.1 "$port" 'uname -sr' 2>/dev/null)"; then
		ok="$r"
		break
	fi
	sleep 3
done
if [ -n "$ok" ]; then answer "ssh: root over the hostfwd works ($ok)"
else answer "ssh: no login over the hostfwd within 120 s"; fi
"$LAB_QEMU_DIR/run.sh" stop --run "$RUN" --name "$name" --timeout 0
echo "answer: $out/answer.txt"
