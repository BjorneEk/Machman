# Guests whose boot hooks live in /etc/rc.local (sysvinit: Debian/Devuan initscripts run it
# only while it is executable; Void's runit stage 2 likewise): the report hook and the
# sshfs boot mounts share the file with whatever the guest already runs there.
# CHECKS: RCLOCAL_INIT RCLOCAL_HOOK RCLOCAL_IDEMPOTENT RCLOCAL_PRISTINE
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

$SH "$S" --uninstall -y >/tmp/unin.log 2>&1
etcsum /etc | grep -v '^[0-9a-f]*  ./ssh/' > /tmp/sum-after
grep -v '^[0-9a-f]*  ./ssh/' /tmp/sum-base > /tmp/sum-base-f
if cmp -s /tmp/sum-base-f /tmp/sum-after; then R RCLOCAL_PRISTINE pass; else
	R RCLOCAL_PRISTINE fail; diff /tmp/sum-base-f /tmp/sum-after | head -10
	tail -n 3 /tmp/unin.log
fi
exit 0
