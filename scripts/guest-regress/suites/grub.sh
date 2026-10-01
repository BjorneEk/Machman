# Kernel-console edits that must never abort a run: an /etc/default/grub holding nothing
# but Machman's line, and a grub.cfg backup that cannot be written.
# CHECKS: GRUB_ONLY_MARKER GRUB_BACKUP_FAIL
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
fake_systemd
mkuser reg
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
exit 0
