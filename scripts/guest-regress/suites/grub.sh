# Kernel-console edits that must never abort a run: an /etc/default/grub holding nothing
# but Machman's line, and a grub.cfg backup that cannot be written. In a VM the run ends with
# the kernel console on hvc1 installed over the guest's own /etc/default/grub; after a reboot
# the kernel really uses it, and the uninstall restores the file byte for byte.
# CHECKS: GRUB_ONLY_MARKER GRUB_BACKUP_FAIL
# BOOT-CHECKS: KC_CMDLINE_AFTER_BOOT KC_CONSOLE_ACTIVE KC_UNINSTALL_RESTORES
. /mnt/machman/share/regress/lib.sh
ORIG=/var/tmp/regress-grub.orig

if boot_phase; then
	if grep -q 'console=hvc1 console=tty0' /proc/cmdline \
		&& [ "$(tr ' ' '\n' < /proc/cmdline | grep '^console=' | tail -n 1)" = console=tty0 ]
	then R KC_CMDLINE_AFTER_BOOT pass; else R KC_CMDLINE_AFTER_BOOT fail; cat /proc/cmdline; fi
	if grep -q '^hvc1 ' /proc/consoles; then R KC_CONSOLE_ACTIVE pass; else
		R KC_CONSOLE_ACTIVE fail; cat /proc/consoles; fi
	$SH "$S" --uninstall -y >/tmp/unin-boot.log 2>&1
	if cmp -s "$ORIG" /etc/default/grub && ! grep -q 'console=hvc1' /boot/grub/grub.cfg; then
		R KC_UNINSTALL_RESTORES pass
	else
		R KC_UNINSTALL_RESTORES fail; diff "$ORIG" /etc/default/grub
		grep -c 'console=hvc1' /boot/grub/grub.cfg; tail -n 4 /tmp/unin-boot.log
	fi
	exit 0
fi

[ -f /etc/fstab ] || : > /etc/fstab
fake_systemd
mkuser reg
# A VM boots from what this suite leaves: keep the guest's own file for the tail below.
had_grub2=yes
[ -d /boot/grub2 ] || had_grub2=no
on_vm && cp -p /etc/default/grub "$ORIG"
mkdir -p /boot/grub /boot/grub2 && touch /boot/grub/grub.cfg /boot/grub2/grub.cfg

# An /etc/default/grub emptied down to ours (the install leaves exactly this line).
: > /etc/default/grub
$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/run1.log 2>&1
grep -q "# $NEW\$" /etc/default/grub || R GRUB_ONLY_MARKER "uncalibrated"
$SH "$S" --uninstall -y >/tmp/unin.log 2>&1
rc=$?
left="$(find /etc/default -name '*machman*' | tr '\n' ' ')"
if [ "$rc" -eq 0 ] && [ ! -s /etc/default/grub ] && [ -z "$left" ] \
	&& [ ! -f /var/lib/machman/state.env ]; then
	R GRUB_ONLY_MARKER pass
else
	R GRUB_ONLY_MARKER "fail (exit $rc)"; echo "left: $left"; tail -n 3 /tmp/unin.log
fi

# A backup that cannot be written: no edit, no rebuild, a reported failure — not an abort.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > /etc/default/grub
cp /etc/default/grub /tmp/grub.orig
for cfg in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
	ln -sf /nonexistent/dir/grub.cfg "$cfg.machman-backup"
done
$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/run2.log 2>&1
rc=$?
if [ "$rc" -eq 4 ] && cmp -s /tmp/grub.orig /etc/default/grub \
	&& grep -q '^STATUS=partial' "$REPORT"; then
	R GRUB_BACKUP_FAIL pass
else
	R GRUB_BACKUP_FAIL "fail (exit $rc)"; tail -n 3 /tmp/run2.log; cat /etc/default/grub
fi

# VM tail: the guest's own file back, the broken backups gone, then the kernel console on
# hvc1 installed for real (the bootloader config is rebuilt) — the boot block checks it.
if on_vm; then
	rm -f /boot/grub/grub.cfg.machman-backup /boot/grub2/grub.cfg.machman-backup
	[ "$had_grub2" = yes ] || rm -rf /boot/grub2
	cp -p "$ORIG" /etc/default/grub
	$SH "$S" --uninstall -y >/tmp/tail-unin.log 2>&1
	cp -p "$ORIG" /etc/default/grub
	$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/tail.log 2>&1
fi
exit 0
