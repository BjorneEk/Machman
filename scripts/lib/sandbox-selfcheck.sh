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
if [[ "$(cat "$root/.owner")" == "$$" && "$suite" =~ ^com\.gustaffranzen\.Machman\.test-[A-Za-z0-9]{6}$ \
	&& -d "$root/data" && -d "$root/home" ]]; then
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

exit "$failures"
