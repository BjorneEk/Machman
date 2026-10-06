#!/bin/bash
#
# Self-check of scripts/lib/sandbox.sh: prints "ok   <check>" or "FAIL <check>: <why>" and
# exits with the failure count. Sweeps only roots it created itself, never /tmp wholesale.
#
set -u

repo="$(cd "$(dirname "$0")/../.." && pwd -P)"
source "$repo/scripts/lib/sandbox.sh"

failures=0
made=()
extra=()
temp="$(getconf DARWIN_USER_TEMP_DIR)"

cleanup() {
	set +e
	local r
	for r in ${made[@]+"${made[@]}"}; do
		sandbox_cleanup "$r"
	done
	for r in ${extra[@]+"${extra[@]}"}; do
		rm -rf "$r"
	done
}
trap cleanup EXIT

ok() { echo "ok   $1"; }
fail() {
	echo "FAIL $1: $2"
	failures=$((failures + 1))
}

# mk <prefix>: a sandbox of this script's own; sets root and suite.
mk() {
	sandbox_create "$1" 6
	root="$SANDBOX_ROOT"
	suite="$SANDBOX_SUITE"
	made+=("$root")
}

dead_pid() {
	sleep 0 &
	local d=$!
	wait "$d"
	echo "$d"
}

# 1
mk mmt
if [[ "$(cat "$root/.owner")" == "$$" &&
	"$suite" =~ ^com\.gustaffranzen\.Machman\.test-[A-Za-z0-9]{6}$ &&
	-d "$root/data" && -d "$root/home" ]]; then
	ok "create: a sandbox has a token, a test suite id, data, home and an owner"
else
	fail "create: a sandbox has a token, a test suite id, data, home and an owner" \
		"owner=$(cat "$root/.owner" 2>&1) suite=$suite"
fi

# 2
mk mmt
dead_pid > "$root/.owner"
mkdir "${temp}${suite}"
sandbox_sweep_root "$root"
if [[ ! -e "$root" && ! -e "${temp}${suite}" ]]; then
	ok "sweep: a sandbox whose owner died goes, with its runtime dir"
else
	fail "sweep: a sandbox whose owner died goes, with its runtime dir" "still there"
fi

# 3
mk mmt
sandbox_sweep_root "$root"
if [[ -d "$root" ]]; then
	ok "sweep: a sandbox whose owner lives stays"
else
	fail "sweep: a sandbox whose owner lives stays" "it was removed"
fi

# 4
mk mmt
rm "$root/.owner"
sandbox_sweep_root "$root"
if [[ -d "$root" ]]; then
	ok "sweep: a young sandbox without an owner stays"
else
	fail "sweep: a young sandbox without an owner stays" "it was removed"
fi

# 5
mk mmt
rm "$root/.owner"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$root"
sandbox_sweep_root "$root"
if [[ ! -e "$root" ]]; then
	ok "sweep: an owner-less sandbox older than a day goes"
else
	fail "sweep: an owner-less sandbox older than a day goes" "still there"
fi

# 6
mk mmt
dead_pid > "$root/.owner"
touch "$root/.keep"
sandbox_sweep_root "$root"
if [[ -d "$root" ]]; then
	ok "sweep: a kept sandbox stays for a day although its owner died"
else
	fail "sweep: a kept sandbox stays for a day although its owner died" "it was removed"
fi

# 7
mk mmt
other="$root-x"
extra+=("$other")
mkdir "$other"
dead_pid > "$other/.owner"
sandbox_sweep_root "$other"
if [[ -d "$other" ]]; then
	ok "sweep: a directory that is not a sandbox name is never touched"
else
	fail "sweep: a directory that is not a sandbox name is never touched" "it was removed"
fi

# 8
mk mmt
mkdir -p "$root/main/.git"
mkdir -p "$root/linked"
echo "gitdir: /x" > "$root/linked/.git"
sandbox_refuse_main_checkout "$root/main" 2>/dev/null
a=$?
sandbox_refuse_main_checkout "$root/linked"
b=$?
if [[ $a == 64 && $b == 0 ]]; then
	ok "refuse: a checkout whose .git is a directory is the main checkout"
else
	fail "refuse: a checkout whose .git is a directory is the main checkout" "got $a and $b"
fi

# 9
mk mmt
SANDBOX_SLOT=
if SANDBOX_SLOT_LABEL=selfcheck sandbox_take_slot "$root/slots" lab.t &&
	[[ "$(cut -d' ' -f1 "$root/slots/lab.t/owner")" == "$$" ]]; then
	sandbox_release_slot
	if [[ ! -e "$root/slots/lab.t" ]]; then
		ok "slot: a free slot is taken and released by its owner"
	else
		fail "slot: a free slot is taken and released by its owner" "release left it"
	fi
else
	fail "slot: a free slot is taken and released by its owner" "could not take it"
fi

# 10
mk mmt
sleep 30 &
holder=$!
mkdir -p "$root/slots/lab.t"
echo "$holder holder" > "$root/slots/lab.t/owner"
SANDBOX_SLOT_WAIT=0 sandbox_take_slot "$root/slots" lab.t
rc=$?
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
if [[ $rc == 75 ]]; then
	ok "slot: a held slot makes a non-waiting taker return 75"
else
	fail "slot: a held slot makes a non-waiting taker return 75" "returned $rc"
fi

# 11
mk mmt
mkdir -p "$root/slots/lab.t"
echo "$(dead_pid) gone" > "$root/slots/lab.t/owner"
if SANDBOX_SLOT_WAIT=0 sandbox_take_slot "$root/slots" lab.t &&
	[[ "$(cut -d' ' -f1 "$root/slots/lab.t/owner")" == "$$" ]]; then
	ok "slot: a slot whose owner died is reclaimed"
else
	fail "slot: a slot whose owner died is reclaimed" "not reclaimed"
fi
sandbox_release_slot

# 12
mk mmt
mkdir -p "$root/slots/lab.t"
echo "1 someone-else" > "$root/slots/lab.t/owner"
SANDBOX_SLOT="$root/slots/lab.t"
sandbox_release_slot
if [[ -d "$root/slots/lab.t" ]]; then
	ok "slot: release leaves another owner's slot alone"
else
	fail "slot: release leaves another owner's slot alone" "it was removed"
fi

# 13
if [[ ${#temp} == 49 ]]; then
	if sandbox_path_budget "com.gustaffranzen.Machman.test-abcd" &&
		! sandbox_path_budget "com.gustaffranzen.Machman.test-abcdef"; then
		ok "budget: a 4-character test token fits sun_path, a 6-character one does not"
	else
		fail "budget: a 4-character test token fits sun_path, a 6-character one does not" \
			"unexpected budget answer"
	fi
else
	echo "skip budget: temp dir is ${#temp} characters"
fi

# 14
# shellcheck disable=SC2016
sandbox_awake sh -c 'i=0
while [ "$i" -lt 50 ]; do
	pmset -g assertions | grep -A1 "PreventSystemSleep named" | grep -q "(pid $$)" && exit 7
	sleep 0.1
	i=$((i + 1))
done
exit 1'
rc=$?
if [[ $rc == 7 ]]; then
	ok "awake: a command runs under PreventSystemSleep and keeps its exit status"
else
	fail "awake: a command runs under PreventSystemSleep and keeps its exit status" "exit $rc"
fi

# 15: a dead lab run's disk image, attached and mounted under its root, is detached by the
# stale sweep before the root goes (the root is never removed through a mounted volume). The
# volume's contents are never read: only hdiutil and mount see it.
sandbox_create mml 4
root="$SANDBOX_ROOT"
made+=("$root")
dead_pid > "$root/.owner"
img=""
if hdiutil create -quiet -size 1m -fs HFS+ -volname mmlsc "$root/v.dmg" &&
	hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$root/v.mnt" "$root/v.dmg"; then
	img="$(sandbox_images_under "$root")"
fi
if [[ -z "$img" ]] || ! sandbox_mounted_under "$root"; then
	fail "sweep: a dead lab run's mounted disk image is detached before its root goes" \
		"could not attach and find a test image (got '$img')"
else
	sandbox_sweep_root "$root"
	if [[ ! -e "$root" ]] && ! hdiutil info | grep -qF "$img" &&
		[[ -z "$(sandbox_images_under "$root")" ]]; then
		ok "sweep: a dead lab run's mounted disk image is detached before its root goes"
	else
		fail "sweep: a dead lab run's mounted disk image is detached before its root goes" \
			"root $([[ -e "$root" ]] && echo stayed || echo went), $img $(hdiutil info |
				grep -qF "$img" && echo "still attached" || echo detached)"
		hdiutil detach -force "$img" >/dev/null 2>&1
	fi
fi

exit "$failures"
