# Uninstall must finish whatever the guest looks like: a guest whose systemctl cannot reach
# a systemd PID 1 (sysvinit with systemd installed). No regular users here.
# CHECKS: SYSTEMCTL_DOWN
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
mkdir -p /usr/local/bin
printf '#!/bin/sh\necho "System has not been booted with systemd" >&2\nexit 1\n' \
	> /usr/local/bin/systemctl
chmod 755 /usr/local/bin/systemctl
$SH "$S" -y --user root --ssh --no-install --no-service >/tmp/run2.log 2>&1
$SH "$S" --uninstall -y --user root >/tmp/unin2.log 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -f /var/lib/machman/state.env ]; then R SYSTEMCTL_DOWN pass; else
	R SYSTEMCTL_DOWN "fail (exit $rc)"; tail -n 3 /tmp/unin2.log; fi
exit 0
