#!/bin/bash
# Spike (r3t, time-boxed; not a lab guest — T14): can the stock OpenBSD arm64 install image
# install itself unattended under QEMU over a serial console, and does the result boot to a
# root login with a virtio console? Writes the run's answer to <run>/openbsd/answer.txt and
# keeps the installed disk as <cache>/spike/openbsd-<version>.raw (for the VZ half).
#
#   openbsd.sh [--source <installNN.img>] [--cache <dir>] [--run <root>] [--keep]
#
# The install image is disk 0 (sd0) and a blank sparse 8 GiB disk the target (sd1). On the
# installer's "(I)nstall, (U)pgrade, (A)utoinstall or (S)hell?" the script picks the shell,
# writes /auto_install.conf from auto_install.conf beside it and runs `install -af`; then it
# powers off, boots the target alone and logs in as root.
#
# ANSWER (2026-10-05, OpenBSD 7.9 arm64 install79.img, QEMU 10.0.3 HVF, edk2): INSTALLS AND
#   BOOTS; NO VIRTIO CONSOLE. The installer prompt reaches the serial console (pluart0) in
#   14 s; `install -af` with auto_install.conf finishes in 102 s (restricted networking needs
#   the default-route and DNS answers); the target boots to a root login in 53 s. But the
#   arm64 GENERIC kernel has no viocon: "virtio2 ... Virtio Console ... no matching child
#   driver; not configured", so there is no /dev/ttyVI00 to MAKEDEV (R3W2-22) and Machman's
#   console ports cannot reach an OpenBSD/arm64 guest. 8.0 is not published for arm64 yet.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../qemu/common.sh
. "$HERE/../../qemu/common.sh"

VERSION=7.9
SOURCE="" RUN="" KEEP=""
ARGS=("$@")
while [ $# -gt 0 ]; do
	case "$1" in
	--source) SOURCE="${2:-}"; shift 2 ;;
	--cache) MACHMAN_LAB_CACHE="${2:-}"; export MACHMAN_LAB_CACHE; shift 2 ;;
	--run) RUN="${2:-}"; shift 2 ;;
	--keep) KEEP=1; shift ;;
	*) sed -n '7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
	esac
done
PY="$(lab_tool python3)"
CON="$LAB_QEMU_DIR/console.py"
spike="$(lab_cache_dir)/spike"
[ -n "$SOURCE" ] || SOURCE="$("$LAB_DIR/fetch.sh" path "openbsd-$VERSION-arm64-install.img")"
[ -f "$SOURCE" ] || lab_die 69 "no OpenBSD install image: pass --source <install${VERSION/./}.img>."
if [ -z "$RUN" ]; then
	# It boots QEMU: inside a lab run (the slot), its own unless one is running already.
	lab_in_run || { lab_session ${KEEP:+--keep} "$0" ${ARGS[@]+"${ARGS[@]}"}; exit $?; }
	RUN="$MACHMAN_LAB_RUN"
fi
lab_check_run_root "$RUN"
trap 'for n in obsd-install obsd; do
	"$LAB_QEMU_DIR/run.sh" stop --run "$RUN" --name "$n" --timeout 0 >/dev/null 2>&1; done' EXIT
out="$RUN/openbsd"
mkdir -p "$out"
answer() { echo "$*" | tee -a "$out/answer.txt"; }
d="$RUN/qemu/obsd-install"
mkdir -p "$d"
cp -c "$SOURCE" "$d/install.img" && chmod 644 "$d/install.img"
dd if=/dev/zero of="$d/target.raw" bs=1 count=0 seek=$((8 * 1073741824)) 2>/dev/null
t0=$SECONDS
"$LAB_QEMU_DIR/run.sh" start --run "$RUN" --name obsd-install --disk "$d/install.img" \
	--disk "$d/target.raw" --cpus 2 --mem 1024 --owner $$ >/dev/null || exit 1
con() { "$PY" "$CON" "$d/serial.sock" --transcript "$d/serial.transcript" "$@"; }
if ! con expect '\(S\)hell\?' --timeout 300; then
	answer "openbsd: BLOCKED — no installer prompt on the serial console in 300 s; tail:"
	tr -d '\r' < "$d/serial.log" | tail -n 8 | sed 's/^/    /' | tee -a "$out/answer.txt"
	exit 1
fi
answer "openbsd: installer prompt on the serial console after $((SECONDS - t0)) s"
con send s >/dev/null
if ! con run --timeout 60 -- true >/dev/null; then
	answer "openbsd: BLOCKED — no installer shell"
	exit 1
fi
# auto_install.conf into the ramdisk, a few lines per command (one shell line each).
con run --timeout 30 -- ': > /auto_install.conf' >/dev/null
while IFS= read -r line; do
	q="$(printf '%s' "$line" | sed "s/'/'\\\\''/g")"
	con run --timeout 30 -- "echo '$q' >> /auto_install.conf" >/dev/null || exit 1
done < "$HERE/auto_install.conf"
t1=$SECONDS
if con run --timeout 1200 -- 'install -af /auto_install.conf' > "$out/install.log" 2>&1 \
	&& grep -q CONGRATULATIONS "$d/serial.transcript"; then
	answer "openbsd: unattended install finished in $((SECONDS - t1)) s"
else
	answer "openbsd: BLOCKED — install -af did not finish; tail:"
	tr -d '\r' < "$d/serial.log" | tail -n 12 | sed 's/^/    /' | tee -a "$out/answer.txt"
	exit 1
fi
con run --timeout 10 -- 'sync' >/dev/null
"$LAB_QEMU_DIR/run.sh" stop --run "$RUN" --name obsd-install --timeout 0
mkdir -p "$spike"
kept="$spike/openbsd-$VERSION.raw"
cp -c "$d/target.raw" "$kept.part" && chmod 444 "$kept.part" && mv "$kept.part" "$kept"

b="$RUN/qemu/obsd"
mkdir -p "$b"
cp -c "$d/target.raw" "$b/disk.raw"
t2=$SECONDS
"$LAB_QEMU_DIR/run.sh" start --run "$RUN" --name obsd --disk "$b/disk.raw" --consoles 1 \
	--cpus 2 --mem 1024 --owner $$ >/dev/null || exit 1
c2() { "$PY" "$CON" "$b/serial.sock" --transcript "$b/serial.transcript" "$@"; }
if c2 login --user root --password lab --nudge 20 --timeout 600; then
	answer "openbsd: the installed system boots to a root login in $((SECONDS - t2)) s"
	answer "kern.version: $(c2 run --timeout 30 -- 'sysctl -n kern.version | head -n 1')"
	VIO='dmesg | grep -i viocon | head -n 3; ls -l /dev/ttyVI00 2>&1'
	answer "viocon: $(c2 run --timeout 30 -- "$VIO" | tr -d '\r' | tr '\n' ';')"
else
	answer "openbsd: the installed system gave no root login in 600 s; tail:"
	tr -d '\r' < "$b/serial.log" | tail -n 12 | sed 's/^/    /' | tee -a "$out/answer.txt"
fi
"$LAB_QEMU_DIR/run.sh" stop --run "$RUN" --name obsd --timeout 0
echo "answer: $out/answer.txt"
