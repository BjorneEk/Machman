# Sandbox helpers shared by scripts/test.sh and scripts/lab.sh.
# Sourced, never executed; functions are prefixed sandbox_; never set -e or exit here.

# The checkout this library belongs to (scripts/lib/sandbox.sh sits two levels below it).
SANDBOX_LIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# sandbox_create <prefix> <xcount>: a fresh /tmp/<prefix>.<token> root with the suite id,
# data dir and fake home of a test run. Sets SANDBOX_ROOT, SANDBOX_TOKEN, SANDBOX_SUITE.
sandbox_create() {
	# /tmp, not $TMPDIR: socket paths built on the run dir must stay under sun_path's 104 bytes.
	SANDBOX_ROOT="$(mktemp -d "/tmp/$1.$(printf 'X%.0s' $(seq 1 "$2"))")"
	SANDBOX_TOKEN="${SANDBOX_ROOT##*.}"
	SANDBOX_SUITE="com.gustaffranzen.Machman.test-$SANDBOX_TOKEN"
	mkdir -p "$SANDBOX_ROOT/data" "$SANDBOX_ROOT/home"
	echo "$$" > "$SANDBOX_ROOT/.owner"
}

# sandbox_awake <command>...: run <command> with the Mac held out of sleep: idle sleep (-i)
# and, on AC power, the maintenance sleep that ends a dark wake (-s; -i alone does not hold a
# dark wake). ContinuousClock counts sleep, so every deadline running across one expires at the
# wake: one test.sh run lost 53 checks to a 15-minute maintenance sleep. No display assertion.
sandbox_awake() {
	if [[ -x /usr/bin/caffeinate ]]; then
		/usr/bin/caffeinate -i -s "$@"
	else
		"$@"
	fi
}

# sandbox_cleanup <root>: remove the root and everything derived from its token.
sandbox_cleanup() (
	# Every path below derives from the token; do nothing on any surprise.
	[[ "$1" =~ ^/tmp/(mmt|mml)\.[A-Za-z0-9]+$ ]] || return 0
	# Best effort: under set -e the first failing rm would skip every later sweep and turn a
	# green run into exit 1 — the script exits with the tests' own status, not cleanup's.
	set +e
	base="${1##*/}"
	token="${base#*.}"
	suite="com.gustaffranzen.Machman.test-$token"
	temp="$(getconf DARWIN_USER_TEMP_DIR)"
	# Never through a mounted volume: detach what is still attached, and leave the root to the
	# next sweep while a volume stays mounted in it (-x: rm never crosses a mount point).
	if sandbox_mounted_under "$1"; then
		sandbox_detach_images "$1"
		if sandbox_mounted_under "$1"; then
			echo "sandbox: a volume is still mounted under $1; not removing it" >&2
			return 0
		fi
	fi
	rm -rfx "$1"
	rm -rf "${temp}${suite}"                              # MachmanPaths.runtimeDir
	rm -f "${temp}_private_tmp_${base}_"*                 # SwiftPM locks named after the fake home
	rm -rf "$HOME/Library/Application Support/$suite"     # defaultDataDir in the real home
	rm -f "$HOME/Library/Preferences/$suite"*.plist       # any defaults domain under the suite
)

# sandbox_is_stale <root>: return 0 when the run that made <root> is gone, 1 to keep it.
sandbox_is_stale() {
	local pid
	# A kept root (lab.sh --keep) survives for a day, whoever owned it.
	if [[ -f "$1/.keep" && -z "$(find "$1/.keep" -mmin +1440 2>/dev/null)" ]]; then
		return 1
	fi
	if [[ -f "$1/.owner" ]]; then
		pid="$(head -n1 "$1/.owner" | tr -cd '0-9')"
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			return 1
		fi
		return 0
	fi
	# No owner: it may be a live run of an older test.sh in another worktree, so only a root
	# older than a day is stale.
	[[ -n "$(find "$1" -maxdepth 0 -mmin +1440 2>/dev/null)" ]]
}

# sandbox_sweep_root <root>: clean <root> when it is a sandbox name and its run is gone. A
# dead lab run's leftovers are stopped first (sandbox_lab_teardown, by token: pids in its pid
# files may have been reused since).
sandbox_sweep_root() {
	[[ -d "$1" && "$1" =~ ^/tmp/(mmt|mml)\.[A-Za-z0-9]+$ ]] || return 0
	sandbox_is_stale "$1" || return 0
	if [[ "$1" == /tmp/mml.* ]]; then
		# shellcheck disable=SC2046
		sandbox_lab_teardown "$1" $(sandbox_token_pids "${1##*.}")
	fi
	sandbox_cleanup "$1"
}

# sandbox_sweep_stale <prefix>...: silently sweep every /tmp/<prefix>.* of a dead run.
sandbox_sweep_stale() {
	local prefix dir
	for prefix in "$@"; do
		for dir in /tmp/"$prefix".*; do
			[[ -d "$dir" ]] && sandbox_sweep_root "$dir"
		done
	done
	return 0
}

# --- what a lab run leaves behind: lab.sh's end of run, its stale sweep and
# scripts/lab/qemu/common.sh's lab_session all stop it with sandbox_lab_teardown -------------

# sandbox_token_pids <token>: same-uid processes whose argv or environment name the run's suite
# or sandbox (the exact token). Never this shell or its parent, the ps and awk doing the scan,
# nor a lab.sh shell (lab.sh's own subshells carry its token).
sandbox_token_pids() {
	[[ -n "${1:-}" ]] || return 0
	ps -axwwE -o pid=,command= -U "$(id -u)" 2>/dev/null | awk -v t="$1" -v me="$$" -v pp="$PPID" '
		{
			if ($1 == me || $1 == pp) next
			if ($2 ~ /(^|\/)(ps|awk)$/) next
			if ($2 ~ /(^|\/)bash$/ && $0 ~ /lab\.sh/) next
			if ($0 ~ ("Machman\\.test-" t "([^A-Za-z0-9]|$)") ||
				$0 ~ ("/mml\\." t "([^A-Za-z0-9]|$)")) print $1
		}'
}

# sandbox_kill_pids <pid>...: TERM, up to 5 s for them to go, then KILL the survivors.
sandbox_kill_pids() {
	local p n alive
	local pids=()
	for p in "$@"; do
		[[ -n "$p" && "$p" != "$$" && "$p" != "$PPID" ]] || continue
		kill -TERM "$p" 2>/dev/null && pids+=("$p")
	done
	((${#pids[@]})) || return 0
	for n in 1 2 3 4 5 6 7 8 9 10; do
		alive=0
		for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
		((alive)) || return 0
		sleep 0.5
	done
	for p in "${pids[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
	return 0
}

# sandbox_images_under <root>: the whole-disk device of every disk image attached from under
# <root> or mounted under it. hdiutil names the physical path (/private/tmp/...), so /tmp/...
# matches in both spellings.
sandbox_images_under() {
	local real
	real="$(cd "$1" 2>/dev/null && pwd -P)" || real="$1"
	hdiutil info 2>/dev/null | awk -v a="$1/" -v b="$real/" -v c="/private$1/" '
		function under(p) { return index(p, a) == 1 || index(p, b) == 1 || index(p, c) == 1 }
		function flush() {
			if (disk != "" && (hit || under(path))) print disk
			path = ""; disk = ""; hit = 0
		}
		/^=+$/ { flush(); next }
		/^image-path *: / { path = $0; sub(/^image-path *: /, "", path); next }
		/^\/dev\/disk/ {
			n = split($0, f, "\t")
			if (disk == "" && f[1] ~ /^\/dev\/disk[0-9]+$/) disk = f[1]
			if (n >= 3 && under(f[3] "/")) hit = 1
		}
		END { flush() }'
}

# sandbox_detach_images <root>: force-detach every disk image sandbox_images_under finds.
sandbox_detach_images() {
	local dev
	for dev in $(sandbox_images_under "$1"); do
		hdiutil detach -force "$dev" >/dev/null 2>&1 || true
	done
	return 0
}

# sandbox_mounted_under <root>: 0 when a volume is mounted at or under <root>.
sandbox_mounted_under() {
	local real
	real="$(cd "$1" 2>/dev/null && pwd -P)" || real="$1"
	mount | awk -v a=" on $1/" -v b=" on $real/" -v c=" on $1 (" -v d=" on $real (" '
		index($0, a) || index($0, b) || index($0, c) || index($0, d) { found = 1 }
		END { exit !found }'
}

# sandbox_bootout_jobs <token>: the run's test-labelled launchd jobs, never any other label.
sandbox_bootout_jobs() {
	local label
	[[ -n "${1:-}" ]] || return 0
	for label in $(launchctl list 2>/dev/null |
		awk -v p="com.gustaffranzen.Machman.test-$1." 'index($3, p) == 1 { print $3 }'); do
		launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
	done
	return 0
}

# sandbox_lab_teardown <root> [<pid>...]: stop everything a lab run left: <pid>... (TERM,
# then KILL), its QEMU guests and lab sshd (scripts/lab's sweeps), the disk images attached
# from under it, and its test-labelled launchd jobs. Removes nothing (sandbox_cleanup does).
sandbox_lab_teardown() {
	local root="$1" lab="$SANDBOX_LIB_REPO/scripts/lab"
	shift
	sandbox_kill_pids "$@"
	[[ -x "$lab/qemu/run.sh" ]] && "$lab/qemu/run.sh" sweep "$root" >/dev/null 2>&1
	[[ -x "$lab/sshd/sshd.sh" ]] && "$lab/sshd/sshd.sh" sweep "$root" >/dev/null 2>&1
	sandbox_detach_images "$root"
	sandbox_bootout_jobs "${root##*.}"
	return 0
}

# sandbox_refuse_main_checkout <repo>: the main checkout (a .git directory, not a linked
# worktree's .git file) builds the products the user runs; no lab run may start there.
sandbox_refuse_main_checkout() {
	if [[ -d "$1/.git" ]]; then
		echo "lab.sh: refusing to run in the main checkout ($1): it builds the products you" \
			"run; use a linked worktree (git worktree add)" >&2
		return 64
	fi
	return 0
}

# sandbox_review_fix_dir <repo>: the orchestrator's review-fix dir (slot locks, xcbuild),
# reached through the git common dir; prints nothing when this clone has none.
sandbox_review_fix_dir() {
	local common
	common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
		return 0
	common="${common%/.git}/.worktrees/machmand-refactor/docs/local/review-fix"
	[[ -d "$common" ]] && echo "$common"
	return 0
}

# sandbox_lab_cache: the fixture cache (several GB): this worktree's git-ignored
# scripts/lab/cache, unless MACHMAN_LAB_CACHE says otherwise.
sandbox_lab_cache() {
	echo "${MACHMAN_LAB_CACHE:-${SANDBOX_LIB_REPO}/scripts/lab/cache}"
}

# sandbox_slot_dir <repo>: where the machine-wide lab slot lives.
sandbox_slot_dir() {
	local rf
	if [[ -n "${MACHMAN_LAB_SLOT_DIR:-}" ]]; then
		echo "$MACHMAN_LAB_SLOT_DIR"
		return 0
	fi
	rf="$(sandbox_review_fix_dir "$1")"
	if [[ -n "$rf" && -d "$rf/locks" ]]; then
		echo "$rf/locks"
	else
		echo "$(sandbox_lab_cache)/locks"
	fi
}

# sandbox_take_slot <dir> <name>: mkdir lock + owner file, stale-pid reclaim. Sets
# SANDBOX_SLOT. SANDBOX_SLOT_WAIT=0 returns 75 instead of waiting.
sandbox_take_slot() {
	local dir="$1" name="$2" slot owner
	slot="$dir/$name"
	mkdir -p "$dir"
	while :; do
		if [[ -d "$slot" ]]; then
			if [[ -f "$slot/owner" ]]; then
				owner="$(cut -d' ' -f1 "$slot/owner" 2>/dev/null | tr -cd '0-9')"
				if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then
					rm -rf "$slot"
				fi
			elif [[ -n "$(find "$slot" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
				rm -rf "$slot"
			fi
		fi
		if mkdir "$slot" 2>/dev/null; then
			echo "$$ ${SANDBOX_SLOT_LABEL:-$PWD}" > "$slot/owner"
			SANDBOX_SLOT="$slot"
			return 0
		fi
		if [[ "${SANDBOX_SLOT_WAIT:-1}" == 0 ]]; then
			return 75
		fi
		echo "lab.sh: the lab slot is held by $(cat "$slot/owner" 2>/dev/null), waiting 30 s" >&2
		sleep 30
	done
}

# sandbox_release_slot: drop the slot, only when this process owns it.
sandbox_release_slot() {
	[[ -n "${SANDBOX_SLOT:-}" && -f "$SANDBOX_SLOT/owner" ]] || return 0
	if [[ "$(cut -d' ' -f1 "$SANDBOX_SLOT/owner" 2>/dev/null)" == "$$" ]]; then
		rm -rf "$SANDBOX_SLOT"
	fi
	return 0
}

# sandbox_path_budget <suite>: <temp><suite>/tty-<8 hex>.sock must fit sun_path (103 bytes
# plus NUL); see MachmanPaths.serialSocketPath. 18 = "/tty-" + 8 hex + ".sock".
sandbox_path_budget() {
	local t
	t="$(getconf DARWIN_USER_TEMP_DIR)"
	(( ${#t} + ${#1} + 18 <= 103 ))
}
