# Guests whose boot hooks live in /etc/rc.local (sysvinit: Debian/Devuan initscripts run it
# only while it is executable; Void's runit stage 2 likewise): the report hook and the
# sshfs boot mounts share the file with whatever the guest already runs there.
# CHECKS: RCLOCAL_INIT RCLOCAL_HOOK RCLOCAL_IDEMPOTENT RCLOCAL_PRISTINE
# CHECKS: RCLOCAL_EXEC RCLOCAL_BEFORE_EXIT RCLOCAL_RUNS RCLOCAL_REENABLED RCLOCAL_DISABLED_KEPT
# CHECKS: BOOT_REPORT_KEEPS_ERRORS
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
mkuser reg
# The classic Debian/Ubuntu template, still on long-lived guests and in every how-to:
# "-e", and a trailing "exit 0" that anything appended after it never reaches. (Today's
# initscripts and Void templates end without one.)
cat > /etc/rc.local <<'RC'
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.

exit 0
RC
chmod 755 /etc/rc.local
cp -p /etc/rc.local /tmp/rc.local.orig
etcsum /etc > /tmp/sum-base

$SH "$S" -y --user reg --two-way --automount-sshfs --no-install --no-service \
	>/tmp/run1.log 2>&1
init="$(sed -n 's/^INIT=//p' "$REPORT")"
case "$init" in
sysv|inittab|runit) R RCLOCAL_INIT pass ;;
*) R RCLOCAL_INIT "fail ($init)"; tail -n 5 /tmp/run1.log ;;
esac
if grep -q "^# BEGIN $NEW-report\$" /etc/rc.local && grep -q "^# BEGIN $NEW\$" /etc/rc.local
then R RCLOCAL_HOOK pass; else R RCLOCAL_HOOK fail; cat -n /etc/rc.local; fi
etcsum /etc > /tmp/sum-1
$SH "$S" -y --user reg --two-way --automount-sshfs --no-install --no-service \
	>/tmp/run2.log 2>&1
etcsum /etc > /tmp/sum-2
if cmp -s /tmp/sum-1 /tmp/sum-2; then R RCLOCAL_IDEMPOTENT pass; else
	R RCLOCAL_IDEMPOTENT fail; diff /tmp/sum-1 /tmp/sum-2 | head -10
fi

# The init only runs an executable rc.local, and only up to its exit.
mode_after_run="$(meta /etc/rc.local | cut -d' ' -f1)"
code_lines() { grep -v '^[[:space:]]*\(#.*\)\{0,1\}$' "$1"; }
if [ "$(code_lines /etc/rc.local | tail -n 1)" = "exit 0" ]; then R RCLOCAL_BEFORE_EXIT pass
else R RCLOCAL_BEFORE_EXIT fail; cat -n /etc/rc.local; fi
# Run it the way the init does, with sshfs swapped for a recorder.
sshfs_bin="$(command -v sshfs)"
cp -p "$sshfs_bin" /tmp/sshfs.real
printf '#!/bin/sh\necho "$*" >> /tmp/sshfs.calls\n' > "$sshfs_bin"
if [ -x /etc/init.d/rc.local ]; then
	/etc/init.d/rc.local start >/tmp/rclocal-run.log 2>&1
else
	sh -c '[ -x /etc/rc.local ] && /etc/rc.local' >/tmp/rclocal-run.log 2>&1   # runit stage 2
fi
# Its report refresh fires 5 s later in the background: let it finish, or it rewrites the
# report under the runs below. (rc[.]local: grep's own command line must not match.)
n=0
while grep -qs 'rc[.]local' /proc/[0-9]*/cmdline && [ "$n" -lt 60 ]; do
	sleep 1
	n=$((n + 1))
done
cp -p /tmp/sshfs.real "$sshfs_bin"
if [ "$(grep -c '/mnt/machman/mounts/' /tmp/sshfs.calls 2>/dev/null)" = 2 ]; then
	R RCLOCAL_RUNS pass
else
	R RCLOCAL_RUNS fail; cat /tmp/rclocal-run.log
fi

$SH "$S" --uninstall -y >/tmp/unin.log 2>&1
if [ "$mode_after_run" = "-rwxr-xr-x" ] \
	&& [ "$(meta /etc/rc.local | cut -d' ' -f1)" = "-rwxr-xr-x" ]; then
	R RCLOCAL_EXEC pass
else
	R RCLOCAL_EXEC "fail ($mode_after_run, then $(meta /etc/rc.local | cut -d' ' -f1))"
fi
etcsum /etc | grep -v '^[0-9a-f]*  ./ssh/' > /tmp/sum-after
grep -v '^[0-9a-f]*  ./ssh/' /tmp/sum-base > /tmp/sum-base-f
if cmp -s /tmp/sum-base-f /tmp/sum-after; then R RCLOCAL_PRISTINE pass; else
	R RCLOCAL_PRISTINE fail; diff /tmp/sum-base-f /tmp/sum-after | head -10
	tail -n 3 /tmp/unin.log
fi

# An rc.local an older Machman left non-executable (its block after the exit, the file
# 0644) is switched back on, and the report says so…
cp /tmp/rc.local.orig /etc/rc.local
printf '# BEGIN %s-report\ntrue\n# END %s-report\n' "$NEW" "$NEW" >> /etc/rc.local
chmod 644 /etc/rc.local
$SH "$S" -y --user reg --two-way --automount-sshfs --no-install --no-service \
	>/tmp/run3.log 2>&1
if [ "$(meta /etc/rc.local | cut -d' ' -f1)" = "-rwxr-xr-x" ] \
	&& [ "$(code_lines /etc/rc.local | tail -n 1)" = "exit 0" ] \
	&& grep -q '^NOTE_[0-9]*=.*/etc/rc.local was not executable — re-enabled' "$REPORT" \
	&& ! grep -q '^ERROR_[0-9]*=.*rc\.local' "$REPORT"; then
	R RCLOCAL_REENABLED pass
else
	R RCLOCAL_REENABLED fail; ls -l /etc/rc.local; grep -E '^(ERROR|NOTE)_' "$REPORT"
fi
$SH "$S" --uninstall -y >/tmp/unin3.log 2>&1

# …while one the guest switched off itself stays off and untouched: the boot mounts fail
# with the remedy, and the report says the boot-time refresh will not run.
cp /tmp/rc.local.orig /etc/rc.local
chmod 644 /etc/rc.local
cp -p /etc/rc.local /tmp/rc.local.off
$SH "$S" -y --user reg --two-way --automount-sshfs --no-install --no-service \
	>/tmp/run4.log 2>&1
if cmp -s /tmp/rc.local.off /etc/rc.local \
	&& [ "$(meta /etc/rc.local)" = "$(meta /tmp/rc.local.off)" ] \
	&& grep -q '^ERROR_[0-9]*=automount-sshfs: /etc/rc.local is not executable' "$REPORT" \
	&& grep -q '^NOTE_[0-9]*=report-refresh: .*boot-time report refresh will not run' "$REPORT" \
	&& ! grep -q '^ERROR_[0-9]*=report-refresh' "$REPORT" \
	&& grep -q 'chmod +x /etc/rc.local' /tmp/run4.log; then
	R RCLOCAL_DISABLED_KEPT pass
else
	R RCLOCAL_DISABLED_KEPT fail; ls -l /etc/rc.local; grep -E '^(ERROR|NOTE)_' "$REPORT"
	diff /tmp/rc.local.off /etc/rc.local | head -8
fi
# S28: the boot-time refresh (--report-only) keeps that run's "partial" explained: its
# status, note, failed steps, error and note lines come back from the state file.
outcome() { grep -E '^(STATUS|FAILED_STEPS|NOTE|ERROR_[0-9]*|NOTE_[0-9]*)=' "$REPORT"; }
outcome > /tmp/outcome-run
$SH "$S" --report-only -q >/tmp/ro4.log 2>&1
outcome > /tmp/outcome-boot
if grep -q '^ERROR_[0-9]*=automount-sshfs: /etc/rc.local is not executable' /tmp/outcome-run \
	&& grep -q '^NOTE=' /tmp/outcome-run && cmp -s /tmp/outcome-run /tmp/outcome-boot; then
	R BOOT_REPORT_KEEPS_ERRORS pass
else
	R BOOT_REPORT_KEEPS_ERRORS fail; diff /tmp/outcome-run /tmp/outcome-boot
fi
exit 0
