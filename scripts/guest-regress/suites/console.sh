# inittab consoles (busybox init on alpine, sysvinit's format on debian): the getty lines
# land in one marker block beside the guest's own lines, a re-run changes nothing, a re-run
# that adds or leaves out a console keeps every login it manages, and uninstall restores the
# file exactly. (/dev/hvcN are stand-in files; HUP to a container's PID 1 is ignored.)
# CHECKS: CONSOLE_INITTAB CONSOLE_IDEMPOTENT CONSOLE_PRISTINE CONSOLE_RESTAGE
# CHECKS: CONSOLE_UNSELECTED_KEPT
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
# A sysvinit guest's inittab where the image has none (debian's initscripts): PID 1 is not
# busybox there, so the lines take sysvinit's id:runlevels:action:process format.
[ -f /etc/inittab ] || printf '1:2345:respawn:/sbin/getty 38400 tty1\n' > /etc/inittab
touch /dev/hvc0 /dev/hvc1
cp -p /etc/inittab /tmp/inittab.orig
block() {
	awk -v m="$NEW" '$0 == "# BEGIN " m { b = 1; next } $0 == "# END " m { b = 0 } b' /etc/inittab
}
# Block lines serving <dev>, whatever the line format.
lines_for() { block | grep -cE "[^a-z0-9]$1([^0-9]|\$)"; }
logins() { sed -n "s/^CONSOLE_LOGINS=//p" /var/lib/machman/state.env 2>/dev/null; }
run_consoles() { # <devices> <log>
	$SH "$S" -y --user root --console --consoles "$1" --no-ssh --no-install --no-service \
		>"$2" 2>&1
}

run_consoles "hvc0 hvc1" /tmp/run1.log
if [ "$(lines_for hvc0)" = 1 ] && [ "$(lines_for hvc1)" = 1 ] \
	&& [ "$(meta /etc/inittab)" = "$(meta /tmp/inittab.orig)" ]; then
	R CONSOLE_INITTAB pass
else
	R CONSOLE_INITTAB fail; cat /etc/inittab; tail -n 4 /tmp/run1.log
fi
cp /etc/inittab /tmp/inittab.1
run_consoles "hvc0 hvc1" /tmp/run2.log
if cmp -s /tmp/inittab.1 /etc/inittab; then R CONSOLE_IDEMPOTENT pass; else
	R CONSOLE_IDEMPOTENT fail; diff /tmp/inittab.1 /etc/inittab; fi
$SH "$S" --uninstall -y --user root >/tmp/unin.log 2>&1
if cmp -s /tmp/inittab.orig /etc/inittab \
	&& [ "$(meta /etc/inittab)" = "$(meta /tmp/inittab.orig)" ]; then
	R CONSOLE_PRISTINE pass
else
	R CONSOLE_PRISTINE fail; diff /tmp/inittab.orig /etc/inittab
fi

# S21: a re-run that adds a console verifies the first one AND keeps its line…
run_consoles hvc0 /tmp/run3.log
run_consoles "hvc0 hvc1" /tmp/run4.log
if [ "$(lines_for hvc0)" = 1 ] && [ "$(lines_for hvc1)" = 1 ] \
	&& [ "$(logins)" = "'hvc0 hvc1'" ]; then
	R CONSOLE_RESTAGE pass
else
	R CONSOLE_RESTAGE "fail ($(logins))"; block; tail -n 4 /tmp/run4.log
fi
# …and one that selects only the second leaves the first one's login in place, managed.
run_consoles hvc1 /tmp/run5.log
if [ "$(lines_for hvc0)" = 1 ] && [ "$(lines_for hvc1)" = 1 ] \
	&& [ "$(logins)" = "'hvc1 hvc0'" ]; then
	R CONSOLE_UNSELECTED_KEPT pass
else
	R CONSOLE_UNSELECTED_KEPT "fail ($(logins))"; block; tail -n 4 /tmp/run5.log
fi
$SH "$S" --uninstall -y --user root >/tmp/unin2.log 2>&1
exit 0
