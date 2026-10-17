# Uninstall must finish whatever the guest looks like: a root-only guest (no account to
# pick), a guest whose systemctl cannot reach a systemd PID 1 (sysvinit with systemd
# installed). No regular users here. And the mount root: one that was there keeps its owner
# and stays, one a run made goes with the parents it made (S66).
# CHECKS: UNINSTALL_ROOT_ONLY SYSTEMCTL_DOWN MOUNTROOT_FOUND_KEPT MOUNTROOT_MADE_REMOVED
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
rm -f /usr/local/bin/systemctl

mkdir -p /srv/found && chown 1234:1234 /srv/found
$SH "$S" -y --user root --sshfs --mountpoint /srv/found --no-install --no-service \
	>/tmp/run3.log 2>&1
owner="$(meta /srv/found)"
$SH "$S" --uninstall -y >/tmp/unin3.log 2>&1
if [ "${owner#* }" = "1234 1234" ] && [ -d /srv/found ]; then R MOUNTROOT_FOUND_KEPT pass; else
	R MOUNTROOT_FOUND_KEPT "fail ($owner)"; ls -lnd /srv/found; tail -n 3 /tmp/run3.log; fi
$SH "$S" -y --user root --sshfs --mountpoint /srv/made/deep --no-install --no-service \
	>/tmp/run4.log 2>&1
made="$(meta /srv/made/deep)"
$SH "$S" --uninstall -y >/tmp/unin4.log 2>&1
if [ -n "$made" ] && [ ! -e /srv/made ]; then R MOUNTROOT_MADE_REMOVED pass; else
	R MOUNTROOT_MADE_REMOVED "fail (${made:-never made})"; ls -lnR /srv; fi
exit 0
