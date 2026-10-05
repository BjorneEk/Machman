# Sourced by every suite, inside its container or VM guest. The payload is the share Machman
# would serve (/mnt/machman/share), the report lands in its GuestReport sibling.
set -u
# The backend running the suite (run.sh --backend): docker (a container: no PID-1 init, faked
# where a suite needs one) or a real guest (qemu, vz) whose init and services are real.
REGRESS_BACKEND="${REGRESS_BACKEND:-docker}"
on_vm() { [ "$REGRESS_BACKEND" != docker ]; }
# The phase (VM backends): run, then — for a suite with "# BOOT-CHECKS:" lines — boot, after
# the harness rebooted the guest with the run's tail left installed. A suite runs only its
# boot block in the boot phase; docker never has one.
boot_phase() { [ "${REGRESS_PHASE:-run}" = boot ]; }
S=/mnt/machman/share/GuestSetup/install.sh
REPORT=/mnt/machman/share/GuestReport/report.env
NEW=machman-regres000001
# The shell that runs the script (run.sh --shell): sh, or e.g. ksh for OpenBSD's lineage.
SH="${REGRESS_SHELL:-sh}"
export DEBIAN_FRONTEND=noninteractive

R() { printf 'RESULT_%s=%s\n' "$1" "$2"; }

# Files + symlink targets, content-hashed — mtime-blind, dangling-link-safe.
etcsum() {
	(cd "$1" && find . -type f | sort | xargs -r md5sum
	 cd "$1" && find . -type l | sort | while read -r l; do
		printf '%s -> %s\n' "$l" "$(readlink "$l")"
	 done)
}

# A regular login user (uid >= 1000) with a home, whatever the distro ships.
mkuser() {
	if command -v useradd >/dev/null 2>&1; then
		useradd -m -s /bin/sh "$1"
	elif command -v pw >/dev/null 2>&1; then
		pw useradd -n "$1" -m -s /bin/sh
	else
		adduser -D -s /bin/sh "$1"
	fi
}

# The script takes its systemd paths on sd_booted's evidence; a container has no PID-1
# systemd, so the shim answers for it (and logs what it was asked). A VM has the real one.
fake_systemd() {
	on_vm && return 0
	mkdir -p /run/systemd/system /usr/local/bin
	# Nothing is running or enabled (is-active/is-enabled answer "inactive"); every other
	# verb succeeds.
	printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> /tmp/systemctl.log\n%s\nexit 0\n' \
		'case "$1" in is-active|is-enabled) exit 3 ;; esac' > /usr/local/bin/systemctl
	chmod 755 /usr/local/bin/systemctl
}

# "<mode> <uid> <gid>" — numeric, the distro's ls either way.
meta() {
	ls -lnd "$1" | awk '{ print substr($1, 1, 10), $3, $4 }'
}

# systemctl_did <start|enable> <unit>: whether the script started (enabled) <unit> — the
# shim's log in a container, systemd itself in a VM.
systemctl_did() {
	if on_vm; then
		case "$1" in
		start) systemctl is-active --quiet "$2" ;;
		enable) systemctl is-enabled --quiet "$2" ;;
		*) return 2 ;;
		esac
	else
		grep -qxF "$1 $2" /tmp/systemctl.log 2>/dev/null
	fi
}
