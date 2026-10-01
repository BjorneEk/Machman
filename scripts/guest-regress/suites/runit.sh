# Void (runit) console logins: Void's own agetty-<dev> service is enabled by a link, a
# Machman-named one is created where Void ships none, and nothing is ever written through a
# stock service's run link into the agetty-generic script every getty shares. Uninstall
# removes exactly what a run added; an older Machman's damage is reported, never touched.
# CHECKS: RUNIT_STOCK_UNTOUCHED RUNIT_STOCK_LINKED RUNIT_OWN_SERVICE RUNIT_IDEMPOTENT
# CHECKS: RUNIT_PRISTINE RUNIT_LEGACY_MIGRATED RUNIT_DAMAGE_REPORTED
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
touch /dev/hvc0 /dev/hvc1
GENERIC=/etc/sv/agetty-generic/run
# Service definitions and the links that enable them (/var/service -> runsvdir/default).
sums() { etcsum /etc/sv; etcsum /etc/runit; }
sums > /tmp/sum-base
etcsum /etc/sv > /tmp/sv-base
run_consoles() { # <log>
	$SH "$S" -y --user root --console --consoles "hvc0 hvc1" --no-ssh --no-install \
		--no-service >"$1" 2>&1
}

run_consoles /tmp/run1.log
etcsum /etc/sv | grep -v '/machman-agetty-' > /tmp/sv-1
if cmp -s /tmp/sv-base /tmp/sv-1; then R RUNIT_STOCK_UNTOUCHED pass; else
	R RUNIT_STOCK_UNTOUCHED fail; diff /tmp/sv-base /tmp/sv-1 | head -8; fi
if [ "$(readlink /var/service/agetty-hvc0)" = /etc/sv/agetty-hvc0 ]; then
	R RUNIT_STOCK_LINKED pass
else
	R RUNIT_STOCK_LINKED fail; ls -l /var/service/; tail -n 4 /tmp/run1.log
fi
OWN=/etc/sv/machman-agetty-hvc1
if [ -f "$OWN/run" ] && [ ! -L "$OWN/run" ] && grep -q "^# $NEW\$" "$OWN/run" \
	&& [ "$(meta "$OWN/run" | cut -d' ' -f1)" = -rwxr-xr-x ] \
	&& [ "$(readlink /var/service/machman-agetty-hvc1)" = "$OWN" ]; then
	R RUNIT_OWN_SERVICE pass
else
	R RUNIT_OWN_SERVICE fail; ls -l "$OWN" /var/service/ 2>&1; cat "$OWN/run" 2>&1
fi
sums > /tmp/sum-1
run_consoles /tmp/run2.log
sums > /tmp/sum-2
if cmp -s /tmp/sum-1 /tmp/sum-2; then R RUNIT_IDEMPOTENT pass; else
	R RUNIT_IDEMPOTENT fail; diff /tmp/sum-1 /tmp/sum-2 | head -8; fi
$SH "$S" --uninstall -y >/tmp/unin1.log 2>&1
sums > /tmp/sum-after
if cmp -s /tmp/sum-base /tmp/sum-after; then R RUNIT_PRISTINE pass; else
	R RUNIT_PRISTINE fail; diff /tmp/sum-base /tmp/sum-after | head -8; fi

# An older Machman's own agetty-hvc1 (a run file it wrote, linked in) becomes the
# Machman-named service at the next run, and the uninstall leaves no hvc1 service at all.
mkdir -p /etc/sv/agetty-hvc1
printf '#!/bin/sh\n# %s\nexec agetty hvc1 115200 vt100\n' "$NEW" > /etc/sv/agetty-hvc1/run
chmod 755 /etc/sv/agetty-hvc1/run
ln -s /etc/sv/agetty-hvc1 /var/service/
run_consoles /tmp/run3.log
migrated=no
[ ! -e /etc/sv/agetty-hvc1 ] && [ ! -e /var/service/agetty-hvc1 ] \
	&& [ ! -L /var/service/agetty-hvc1 ] && [ -f "$OWN/run" ] \
	&& [ -e /var/service/machman-agetty-hvc1 ] && migrated=yes
$SH "$S" --uninstall -y >/tmp/unin2.log 2>&1
sums > /tmp/sum-after2
if [ "$migrated" = yes ] && cmp -s /tmp/sum-base /tmp/sum-after2; then
	R RUNIT_LEGACY_MIGRATED pass
else
	R RUNIT_LEGACY_MIGRATED "fail (migrated: $migrated)"; ls -l /etc/sv /var/service/
	tail -n 4 /tmp/run3.log
fi

# The damage an older Machman did (agetty-generic/run overwritten through a stock link) is
# reported with Void's own repair, and neither a run nor the uninstall touches a stock
# service.
cp -p "$GENERIC" /tmp/generic.orig
printf '#!/bin/sh\n# %s\nexec agetty hvc0 115200 vt100\n' "$NEW" > "$GENERIC"
cp -p "$GENERIC" /tmp/generic.damaged
run_consoles /tmp/run4.log
rc=$?
reported=no
grep -q '^ERROR_[0-9]*=console: .*xbps-install -f runit-void' "$REPORT" && reported=yes
$SH "$S" --uninstall -y >/tmp/unin3.log 2>&1
urc=$?
cp -p /tmp/generic.orig "$GENERIC"
sums > /tmp/sum-after3
if [ "$rc" -eq 4 ] && [ "$reported" = yes ] && [ "$urc" -eq 4 ] \
	&& grep -q 'xbps-install -f runit-void' /tmp/unin3.log \
	&& cmp -s /tmp/sum-base /tmp/sum-after3; then
	R RUNIT_DAMAGE_REPORTED pass
else
	R RUNIT_DAMAGE_REPORTED "fail (exit $rc, uninstall $urc, reported: $reported)"
	diff /tmp/sum-base /tmp/sum-after3 | head -6; tail -n 3 /tmp/unin3.log
fi
exit 0
