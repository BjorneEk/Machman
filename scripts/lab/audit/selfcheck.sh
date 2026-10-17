#!/bin/bash
#
# Self-check of the host-quiet audits: every audit is proven to FAIL on a provoked breach
# (injected samples, plus one real 1x1 never-activated window at an off-screen origin in a
# helper process) and to pass a quiet run. Never touches the pasteboard or focus. Prints
# "ok   <check>" or "FAIL <check>: <why>"; exits with the failure count.
#
set -u

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../../.." && pwd -P)"
source "$repo/scripts/lib/sandbox.sh"

hw="$("$here/build.sh")" || exit 1
sandbox_create mml 4
root="$SANDBOX_ROOT"
token="$SANDBOX_TOKEN"
suite="$SANDBOX_SUITE"
other="$(mktemp -d /tmp/hwsc.XXXXXX)"
trap 'sandbox_cleanup "$root"; rm -rf "$other"' EXIT
mkdir -p "$root/pids"

failures=0
ok() { echo "ok   $1"; }
fail() {
	echo "FAIL $1: $2"
	failures=$((failures + 1))
}

# watch <dir> [hostwatch args...]: a watch of about 3 s; sets summary.
watch() {
	local dir="$root/w-$1"
	shift
	"$hw" watch --token "$token" --run "$root" --out "$dir" --interval 0.25 "$@" &
	local pid=$!
	sleep 3
	touch "$dir/stop"
	wait "$pid"
	WATCH_STATUS=$?
	summary="$(cat "$dir/summary.txt" 2>/dev/null)"
}

# 1
watch quiet
if [[ $WATCH_STATUS == 0 && "$summary" != *BREACH* && "$summary" == *"OK window"* ]]; then
	ok "audit: a quiet run has no breach"
else
	fail "audit: a quiet run has no breach" "status $WATCH_STATUS: $summary"
fi

# 2
watch window --inject window --inject-after 2
if [[ $WATCH_STATUS == 3 && "$summary" == *"BREACH window pid -1"* ]]; then
	ok "audit window: an on-screen window of a lab process is a breach"
else
	fail "audit window: an on-screen window of a lab process is a breach" \
		"status $WATCH_STATUS: $summary"
fi

# real_window <dir> [hostwatch args...]: a watch while a helper under the test suite orders one
# real window, off every screen, for ~1.2 s; sets summary and probe (the helper's pid).
real_window() {
	local dir="$root/w-$1" wpid
	shift
	"$hw" watch --token "$token" --run "$root" --out "$dir" --interval 0.25 "$@" &
	wpid=$!
	sleep 1
	env MACHMAN_SUITE_ID="$suite" "$hw" window-probe --seconds 4 &
	probe=$!
	wait "$probe"
	touch "$dir/stop"
	wait "$wpid"
	summary="$(cat "$dir/summary.txt" 2>/dev/null)"
}

# window_row_ok: the helper's window is a breach and nothing of the run took focus: no lab
# process with a Dock icon, active or frontmost. Another app coming to the front is the user's,
# only a note, as in every lab run (Q44: requiring the front unchanged failed on a user's switch).
# Focus is judged only from the watch summary: 3b's switch reaches it and lsappinfo (a PATH
# shim), and no other live read of the front app.
window_row_ok() {
	[[ "$summary" == *"BREACH window pid $probe "* && "$summary" != *"BREACH policy"* &&
		"$summary" != *"BREACH active"* && "$summary" != *"BREACH frontmost"* ]]
}

# 3: a real window, off every screen, ordered for ~1.2 s by a helper under the test suite
real_window real
if window_row_ok; then
	ok "audit window: a real off-screen window of a lab process is a breach"
else
	fail "audit window: a real off-screen window of a lab process is a breach" "$summary"
fi

# 3b: the user brings another app to the front during it and stays there: only a note, never
# the run's breach. The switch shows wherever a rule could look: in the watch (a real process
# outside the run, injected as frontmost to the end) and in `lsappinfo front`, which a PATH shim,
# first on PATH in this row's subshell only, answers with another app on every call.
shim="$root/shim"
mkdir -p "$shim"
cat >"$shim/lsappinfo" <<'SHIM'
#!/bin/sh
# The front app of a user who keeps switching apps: another ASN on every call.
n="$(cat "$0.calls" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$0.calls"
echo "ASN:0x0-0x$((n + 1)):"
SHIM
chmod +x "$shim/lsappinfo"
env -i "$hw" idle --seconds 6 &
user=$!
if (
	PATH="$shim:$PATH"
	real_window user --inject "front=$user" --inject-after 6
	echo "$summary"
	window_row_ok && [[ "$summary" == *"NOTE frontmost injected ($user)"* ]]
) >"$root/user-row.txt"; then
	ok "Q44: the user's app coming to the front during the real-window row is only a note"
else
	fail "Q44: the user's app coming to the front during the real-window row is only a note" \
		"pid $user: $(cat "$root/user-row.txt")"
fi
wait "$user"

# 3c: the run's own window taking the front (its helper injected as frontmost) fails the row
real_window steal --inject front=lab-window
if ! window_row_ok && [[ "$summary" == *"BREACH frontmost pid $probe "* ]]; then
	ok "Q44: the run's own window coming to the front fails the real-window row"
else
	fail "Q44: the run's own window coming to the front fails the real-window row" \
		"pid $probe: $summary"
fi

# 4
watch policy --inject policy --inject-after 2
if [[ $WATCH_STATUS == 3 && "$summary" == *"BREACH policy pid -1"* ]]; then
	ok "audit policy: a lab process with a Dock icon is a breach"
else
	fail "audit policy: a lab process with a Dock icon is a breach" "$WATCH_STATUS: $summary"
fi

# 5
watch front --inject frontmost --inject-after 2
if [[ $WATCH_STATUS == 3 && "$summary" == *"BREACH frontmost pid -1"* ]]; then
	ok "audit frontmost: a frontmost lab process is a breach"
else
	fail "audit frontmost: a frontmost lab process is a breach" "$WATCH_STATUS: $summary"
fi

# 5b
watch active --inject active --inject-after 2
if [[ $WATCH_STATUS == 3 && "$summary" == *"BREACH active pid -1"* &&
	"$summary" != *"OK active"* ]]; then
	ok "audit active: an active lab process is a breach"
else
	fail "audit active: an active lab process is a breach" "$WATCH_STATUS: $summary"
fi

# 6
watch pb --inject pasteboard --inject-after 2
if [[ $WATCH_STATUS == 3 && "$summary" == *"BREACH pasteboard changeCount"* ]]; then
	ok "audit pasteboard: a change while a lab process is frontmost is a breach"
else
	fail "audit pasteboard: a change while a lab process is frontmost is a breach" \
		"$WATCH_STATUS: $summary"
fi

# 6b the user's own copy is a note, never a breach
watch pbuser --inject pasteboard-user --inject-after 2
if [[ $WATCH_STATUS == 0 && "$summary" == *"NOTE pasteboard"*"(user copy?)"* &&
	"$summary" != *"BREACH pasteboard"* ]]; then
	ok "audit pasteboard: a change while another app is frontmost is only a note"
else
	fail "audit pasteboard: a change while another app is frontmost is only a note" \
		"$WATCH_STATUS: $summary"
fi

# 7
prot="$root/protected"
mkdir -p "$prot/sub"
echo a >"$prot/a"
echo b >"$prot/b"
echo c >"$prot/sub/c"
"$hw" snapshot --root "$prot" --out "$root/s1.json"
sleep 1
echo changed >"$prot/a"
rm "$prot/b"
echo d >"$prot/d"
"$hw" snapshot --root "$prot" --out "$root/s2.json"
"$hw" diff --before "$root/s1.json" --after "$root/s2.json" --out "$root/d1.txt"
status=$?
count="$(grep -c '^BREACH snapshot' "$root/d1.txt")"
if [[ $status == 3 && $count == 3 ]]; then
	ok "audit snapshot: a write under a protected root is a breach"
else
	fail "audit snapshot: a write under a protected root is a breach" \
		"status $status, $count breaches: $(cat "$root/d1.txt")"
fi

# 8: a change in a path that doesn't name this run, while a non-lab Machman process runs
mkdir -p "$other/protected/sub"
echo a >"$other/protected/a"
"$hw" snapshot --root "$other/protected" --out "$root/o1.json"
echo b >"$other/protected/b"
"$hw" snapshot --root "$other/protected" --out "$root/o2.json"
echo "123 /x/Machman.app/Contents/MacOS/Machman" >"$root/nonlab.txt"
"$hw" diff --before "$root/o1.json" --after "$root/o2.json" --out "$root/d2.txt" \
	--non-lab "$root/nonlab.txt" --token "$token"
status=$?
# the same change under a path naming the run stays a breach
named="$root/named"
mkdir -p "$named"
echo a >"$named/a"
"$hw" snapshot --root "$named" --out "$root/n1.json"
echo b >"$named/b"
"$hw" snapshot --root "$named" --out "$root/n2.json"
"$hw" diff --before "$root/n1.json" --after "$root/n2.json" --out "$root/d3.txt" \
	--non-lab "$root/nonlab.txt" --token "$token"
status3=$?
"$hw" diff --before "$root/o1.json" --after "$root/o2.json" --out "$root/d4.txt" \
	--token "$token"
status4=$?
if [[ $status == 0 && "$(grep -c '^WARN snapshot' "$root/d2.txt")" == 1 && $status3 == 3 &&
	$status4 == 3 ]]; then
	ok "audit snapshot: with a non-lab Machman process running the same change is a warning"
else
	fail "audit snapshot: with a non-lab Machman process running the same change is a warning" \
		"$status/$status3/$status4: $(cat "$root/d2.txt" "$root/d3.txt")"
fi

# 8b: the lab's own vmhosts never pass for non-lab Machman processes. Injected sightings: one
# read whole once and then only by its path (exiting, its pid file already removed), one first
# read mid-exec (launchd's arguments), and one only ever read mid-exec (unclassified: a note).
# A Machman preferences change while only they ran is a breach; the same change while a .dev
# vmhost ran (read whole) is a warning.
prefs="$other/Preferences"
plist="$prefs/com.gustaffranzen.Machman.dev.agent.plist"
mkdir -p "$prefs"
"$hw" snapshot --root "$prefs" --out "$root/p1.json"
echo changed >"$plist"
"$hw" snapshot --root "$prefs" --out "$root/p2.json"
# Only the injected sightings (negative pids) count: a real Machman process of another lab run
# or the user's .dev agent may be running beside this self-check.
injected() { grep '^-' "$1" > "$1.injected"; echo "$1.injected"; }
watch classify --inject lab-exit --inject lab-exec --inject exec-only --inject-after 2
classify="$root/w-classify"
nonlab5="$(injected "$classify/non-lab-machman.txt")"
"$hw" diff --before "$root/p1.json" --after "$root/p2.json" --out "$root/d5.txt" \
	--non-lab "$nonlab5" --token "$token"
status5=$?
if [[ $WATCH_STATUS == 0 && ! -s "$nonlab5" &&
	"$(grep -c '^-[34] ' "$classify/lab-processes.txt")" == 2 &&
	"$(grep -c 'NOTE classify' <<<"$summary")" == 1 &&
	"$summary" == *"NOTE classify pid -6 "* && $status5 == 3 &&
	"$(cat "$root/d5.txt")" == "BREACH snapshot added $plist" ]]; then
	ok "audit classify: an exiting or exec'ing lab vmhost leaves a Machman change a breach"
else
	fail "audit classify: an exiting or exec'ing lab vmhost leaves a Machman change a breach" \
		"$WATCH_STATUS/$status5: non-lab [$(cat "$nonlab5")] lab [$(
			grep '^-' "$classify/lab-processes.txt")] $(cat "$root/d5.txt")"
fi
watch devhost --inject non-lab --inject-after 2
nonlab6="$(injected "$root/w-devhost/non-lab-machman.txt")"
"$hw" diff --before "$root/p1.json" --after "$root/p2.json" --out "$root/d6.txt" \
	--non-lab "$nonlab6" --token "$token"
status6=$?
if [[ "$(cat "$nonlab6")" == "-5 "*MachmanVMHost && $status6 == 0 &&
	"$(cat "$root/d6.txt")" == "WARN snapshot added "*"(a non-lab Machman process ran: -5)" ]]; then
	ok "audit classify: a .dev vmhost read whole is a non-lab Machman process"
else
	fail "audit classify: a .dev vmhost read whole is a non-lab Machman process" \
		"$status6: non-lab [$(cat "$nonlab6")] $(cat "$root/d6.txt")"
fi

# 8c: a real stand-in vmhost (a copy of this helper at a Machman app path, the run's socket dir
# in its arguments, nothing else naming the run) is the lab's
standin="$other/MachmanVMHost.app/Contents/MacOS/MachmanVMHost"
mkdir -p "$(dirname "$standin")"
cp "$hw" "$standin"
dir="$root/w-standin"
"$hw" watch --token "$token" --run "$root" --out "$dir" --interval 0.25 &
wpid=$!
sleep 1
env -i "$standin" idle --seconds 1.5 \
	--socket "$(getconf DARWIN_USER_TEMP_DIR)com.gustaffranzen.Machman.test-$token/vm-sc.sock" &
spid=$!
wait "$spid"
sleep 0.5
touch "$dir/stop"
wait "$wpid"
if grep -q "^$spid .*/MachmanVMHost.app/Contents/MacOS/MachmanVMHost$" "$dir/lab-processes.txt" &&
	! grep -q "^$spid " "$dir/non-lab-machman.txt"; then
	ok "audit classify: a real process naming the run's sockets is the lab's"
else
	fail "audit classify: a real process naming the run's sockets is the lab's" \
		"pid $spid; non-lab [$(cat "$dir/non-lab-machman.txt")]"
fi

# 9
"$hw" snapshot --token "$token" --out "$root/default.json"
if python3 - "$root/default.json" "$(id -un)" <<'PY'
import json, os, pwd, sys
doc = json.load(open(sys.argv[1]))
home = pwd.getpwuid(os.getuid()).pw_dir
ssh = [r for r in doc["roots"] if r["path"] == home + "/.ssh"]
assert ssh and ssh[0]["metaOnly"] is True, "no metaOnly .ssh root"
for path, e in doc["entries"].items():
    assert not path.startswith(home + "/.machman"), path
    if path.startswith(home + "/.ssh"):
        assert "sha256" not in e, path
PY
then
	ok "audit snapshot: default roots read ~/.ssh by metadata only and skip ~/.machman"
else
	fail "audit snapshot: default roots read ~/.ssh by metadata only and skip ~/.machman" \
		"see the python assertion"
fi

# 9b: the default roots catch a change under a home: a Machman preferences plist (the
# namePrefix walk) and a launch agent are flagged, another app's preferences are not.
fake="$root/fakehome"
mkdir -p "$fake/Library/Preferences" "$fake/Library/LaunchAgents"
echo a >"$fake/Library/Preferences/com.example.other.plist"
"$hw" snapshot --home "$fake" --token "$token" --out "$root/h1.json"
agentplist="$fake/Library/Preferences/com.gustaffranzen.Machman.dev.agent.plist"
jobplist="$fake/Library/LaunchAgents/com.gustaffranzen.Machman.dev.vm.selfcheck.plist"
echo b >"$agentplist"
echo c >"$jobplist"
echo d >"$fake/Library/Preferences/com.example.other.plist"
"$hw" snapshot --home "$fake" --token "$token" --out "$root/h2.json"
"$hw" diff --before "$root/h1.json" --after "$root/h2.json" --out "$root/d7.txt"
status7=$?
if [[ $status7 == 3 ]] && grep -qxF "BREACH snapshot added $agentplist" "$root/d7.txt" &&
	grep -qxF "BREACH snapshot added $jobplist" "$root/d7.txt" &&
	! grep -q "com.example.other" "$root/d7.txt"; then
	ok "audit snapshot: default roots flag a Machman preferences plist and a launch agent"
else
	fail "audit snapshot: default roots flag a Machman preferences plist and a launch agent" \
		"status $status7: $(cat "$root/d7.txt")"
fi

# 10
home="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
"$hw" snapshot --root "$home/.machman/x" --out "$root/refused.json"
status=$?
if [[ $status == 64 && ! -e "$root/refused.json" ]]; then
	ok "audit snapshot: a root under ~/.machman is refused"
else
	fail "audit snapshot: a root under ~/.machman is refused" "exit $status"
fi

exit "$failures"
