# Uninstall must finish whatever the guest looks like: a root-only guest (no account to
# pick), a guest whose systemctl cannot reach a systemd PID 1 (sysvinit with systemd
# installed). No regular users here.
# CHECKS: UNINSTALL_ROOT_ONLY SYSTEMCTL_DOWN
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
$SH "$S" -y --user root --ssh --no-install --no-service >/tmp/run1.log 2>&1
$SH "$S" --uninstall -y >/tmp/unin1.log 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "$NEW" /root/.ssh/authorized_keys 2>/dev/null \
	&& [ ! -f /var/lib/machman/state.env ]; then
	R UNINSTALL_ROOT_ONLY pass
else
	R UNINSTALL_ROOT_ONLY "fail (exit $rc)"; tail -n 3 /tmp/unin1.log
fi

# A systemctl that exists but is not talking to PID 1.
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
