# === machman-setup: 30-state ===
# Persistent guest-side state: what this script configured, and which version wrote it —
# so a re-run can offer reconfiguration instead of starting blind, and a newer script can
# repair older layouts. One flat key=value file, written after the act phase.

STATE_VERSION=1
STATE_DIR=""
STATE_FILE=""
HAD_STATE=0
# What the state file taught us (empty until read).
ST_SCRIPT_VERSION=""
ST_CONFIGURED=""           # space-separated feature ids
ST_CONSOLE_LOGINS=""
ST_KERNEL_CONSOLE=""
ST_KERNEL_CONSOLE_METHOD=""
ST_SSH_USER=""
ST_AUTOMOUNT_SSHFS=""      # space-separated mount names
ST_LAST_STATUS=""          # ok|partial from the last real run — --report-only keeps it

state_paths() {
	case "$OS_FAMILY" in
	darwin|freebsd|openbsd|netbsd) STATE_DIR="/var/db/machman" ;;
	*) STATE_DIR="/var/lib/machman" ;;
	esac
	STATE_FILE="$STATE_DIR/state.env"
	return 0
}

# Parsed, never sourced — same reasoning as /etc/os-release.
state_get() {
	sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1 | tr -d "'"
}

read_state() {
	state_paths
	[ -r "$STATE_FILE" ] || return 0
	# A cloned guest carries the source VM's state; its records describe artifacts
	# tagged with the source's marker, which the ownership probes treat as foreign.
	# Start fresh instead of trusting them. (Pre-marker v3 states pass as ours.)
	_rs_marker="$(state_get MARKER)"
	if [ -n "$_rs_marker" ] && [ "$_rs_marker" != "$MARKER" ]; then
		note "this guest looks cloned from another Machman VM — treating it as new"
		return 0
	fi
	HAD_STATE=1
	ST_SCRIPT_VERSION="$(state_get SCRIPT_VERSION)"
	ST_CONFIGURED="$(state_get CONFIGURED)"
	ST_CONSOLE_LOGINS="$(state_get CONSOLE_LOGINS)"
	ST_KERNEL_CONSOLE="$(state_get KERNEL_CONSOLE)"
	ST_KERNEL_CONSOLE_METHOD="$(state_get KERNEL_CONSOLE_METHOD)"
	ST_SSH_USER="$(state_get SSH_USER)"
	ST_AUTOMOUNT_SSHFS="$(state_get AUTOMOUNT_SSHFS)"
	ST_LAST_STATUS="$(state_get LAST_STATUS)"
	verbose state "v${ST_SCRIPT_VERSION:-?} configured=[${ST_CONFIGURED:-}]"
	# Repairs for older layouts land here as the versions accumulate. v3 is the first
	# version writing state at all (v2 left only marker-tagged artifacts), so there is
	# nothing to migrate yet — v2 artifacts are simply re-detected feature by feature.
	return 0
}

state_was_configured() {
	has_word "$1" "$ST_CONFIGURED"
}

# write_state <configured feature ids, space-separated>
write_state() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	mkdir -p "$STATE_DIR" 2>/dev/null || {
		step_failed state "could not create $STATE_DIR — re-runs will not remember choices" \
			"Create it yourself and re-run."
		return 0
	}
	{
		printf 'STATE_VERSION=%s\n' "$STATE_VERSION"
		printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
		printf "MARKER='%s'\n" "$MARKER"
		printf "CONFIGURED='%s'\n" "$1"
		if [ -n "$FAILED_STEPS" ]; then
			printf "LAST_STATUS='partial'\n"
		else
			printf "LAST_STATUS='ok'\n"
		fi
		[ -n "$CONSOLE_MANAGED" ] && printf "CONSOLE_LOGINS='%s'\n" "$CONSOLE_MANAGED"
		[ -n "$KC_DEVICE_DONE" ] && printf "KERNEL_CONSOLE='%s'\n" "$KC_DEVICE_DONE"
		[ -n "$KC_METHOD_DONE" ] && printf "KERNEL_CONSOLE_METHOD='%s'\n" "$KC_METHOD_DONE"
		[ -n "$U" ] && printf "SSH_USER='%s'\n" "$U"
		[ -n "$SSHFSAUTO_DONE" ] && printf "AUTOMOUNT_SSHFS='%s'\n" "$SSHFSAUTO_DONE"
		:
	} > "$STATE_FILE.tmp"
	mv "$STATE_FILE.tmp" "$STATE_FILE"
	chmod 600 "$STATE_FILE" 2>/dev/null || true
	verbose state "wrote $STATE_FILE"
	return 0
}

remove_state() {
	rm -f "$STATE_FILE" 2>/dev/null || true
	rmdir "$STATE_DIR" 2>/dev/null || true
	return 0
}

# ------------------------------------------------------------------------ mounts.list ----

# kind<TAB>name<TAB>hostpath per line. Consumed by the automount features; missing file
# just means no mounts (older payloads, mount-less VMs).
MOUNTS_SSHFS=""            # newline-separated "name<TAB>hostpath"
MOUNTS_SSHFS_NAMES=""      # space-separated names, for menus and the state file

read_mounts_list() {
	[ -r "$MOUNTS_LIST" ] || return 0
	_rml_tab="$(printf '\t')"
	while IFS="$_rml_tab" read -r _rml_kind _rml_name _rml_path; do
		case "$_rml_kind" in
		''|'#'*) continue ;;
		sshfs)
			if [ -z "$MOUNTS_SSHFS" ]; then
				MOUNTS_SSHFS="$_rml_name$_rml_tab$_rml_path"
			else
				MOUNTS_SSHFS="$MOUNTS_SSHFS
$_rml_name$_rml_tab$_rml_path"
			fi
			MOUNTS_SSHFS_NAMES="$MOUNTS_SSHFS_NAMES $_rml_name"
			;;
		esac
	done < "$MOUNTS_LIST"
	MOUNTS_SSHFS_NAMES="${MOUNTS_SSHFS_NAMES# }"
	verbose detect "sshfs mounts=[${MOUNTS_SSHFS_NAMES:-none}]"
	return 0
}
