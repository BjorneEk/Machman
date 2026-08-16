#!/bin/sh
# Machman console login installer. Do not edit: Machman regenerates this file at
# every VM start to match the attached consoles.
#
# Installs a login prompt (launchd getty) for each Machman console. Safe to
# re-run at any time; run with --uninstall to remove everything it installed.
set -eu

SCRIPT_VERSION=1
PREFIX="com.machman.console-getty"
DAEMONS="/Library/LaunchDaemons"

PAYLOAD_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ ! -r "$PAYLOAD_DIR/machman.env" ]; then
	echo "machman.env is missing next to this script — run the copy Machman put in" >&2
	echo "the share, not install.sh on its own." >&2
	exit 1
fi
# VM_NAME, PORTS
. "$PAYLOAD_DIR/machman.env"

if [ "$(id -u)" -ne 0 ]; then
	echo "Please run with sudo:  sudo sh \"$0\" ${1:-}" >&2
	exit 1
fi

remove_all() {
	for plist in "$DAEMONS/$PREFIX".*.plist; do
		[ -e "$plist" ] || continue
		label="$(basename "$plist" .plist)"
		launchctl bootout "system/$label" 2>/dev/null || true
		rm -f "$plist"
		echo "removed $label"
	done
}

if [ "${1:-}" = "--uninstall" ]; then
	remove_all
	echo "done — all Machman console logins removed."
	exit 0
fi

if [ -z "$PORTS" ]; then
	echo "This VM has no consoles attached — add one in Machman first."
	exit 0
fi

# Clean slate: drop logins for consoles that were removed, then install the set.
remove_all >/dev/null

i=0
installed=0
total=0
for port in $PORTS; do
	total=$((total + 1))
done
for port in $PORTS; do
	if [ ! -e "/dev/$port" ]; then
		echo "warning: /dev/$port is not present in this guest — skipped" >&2
		i=$((i + 1))
		continue
	fi
	plist="$DAEMONS/$PREFIX.$i.plist"
	cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$PREFIX.$i</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/libexec/getty</string>
		<string>std.115200</string>
		<string>$port</string>
	</array>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
PLIST
	chown root:wheel "$plist"
	chmod 644 "$plist"
	launchctl bootstrap system "$plist"
	echo "installed login on /dev/$port"
	installed=$((installed + 1))
	i=$((i + 1))
done
echo "done — $installed of $total console login(s) active." \
	"Prompts appear in the Machman consoles immediately."
