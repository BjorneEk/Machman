# inittab consoles (busybox init): the getty lines land in one marker block beside the
# guest's own lines, a re-run changes nothing, and uninstall restores the file exactly.
# (/dev/hvcN are stand-in files; HUP to a container's PID 1 is ignored.)
# CHECKS: CONSOLE_INITTAB CONSOLE_IDEMPOTENT CONSOLE_PRISTINE
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
touch /dev/hvc0 /dev/hvc1
cp -p /etc/inittab /tmp/inittab.orig
$SH "$S" -y --user root --console --consoles "hvc0 hvc1" --no-ssh --no-install --no-service \
	>/tmp/run1.log 2>&1
if [ "$(awk -v m="$NEW" '$0 == "# BEGIN " m { b = 1; next } $0 == "# END " m { b = 0 } b' \
	/etc/inittab | grep -c '^hvc[01]::respawn:')" = 2 ] \
	&& [ "$(meta /etc/inittab)" = "$(meta /tmp/inittab.orig)" ]; then
	R CONSOLE_INITTAB pass
else
	R CONSOLE_INITTAB fail; cat /etc/inittab; tail -n 4 /tmp/run1.log
fi
cp /etc/inittab /tmp/inittab.1
$SH "$S" -y --user root --console --consoles "hvc0 hvc1" --no-ssh --no-install --no-service \
	>/tmp/run2.log 2>&1
if cmp -s /tmp/inittab.1 /etc/inittab; then R CONSOLE_IDEMPOTENT pass; else
	R CONSOLE_IDEMPOTENT fail; diff /tmp/inittab.1 /etc/inittab; fi
$SH "$S" --uninstall -y --user root >/tmp/unin.log 2>&1
if cmp -s /tmp/inittab.orig /etc/inittab \
	&& [ "$(meta /etc/inittab)" = "$(meta /tmp/inittab.orig)" ]; then
	R CONSOLE_PRISTINE pass
else
	R CONSOLE_PRISTINE fail; diff /tmp/inittab.orig /etc/inittab
fi
exit 0
