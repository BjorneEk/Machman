# grubby (BLS: Fedora/RHEL): the kernel console's arguments land in every boot entry and
# leave them at uninstall — also after a later run for other features, which keeps the
# record the uninstall needs. The boot entry is fabricated (a container has no /boot).
# CHECKS: KC_STATE_KEPT KC_GRUBBY_UNINSTALL
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
fake_systemd
mkuser reg
K=6.9.0-1.fc42.aarch64
[ -s /etc/machine-id ] || echo 0123456789abcdef0123456789abcdef > /etc/machine-id
mkdir -p /boot/loader/entries
printf 'title Fedora Linux (%s) 42\nversion %s\nlinux /vmlinuz-%s\ninitrd /initramfs-%s.img\n' \
	"$K" "$K" "$K" "$K" > "/boot/loader/entries/$(cat /etc/machine-id)-$K.conf"
printf 'options root=UUID=1234 ro rhgb quiet\n' >> "/boot/loader/entries/$(cat /etc/machine-id)-$K.conf"
touch "/boot/vmlinuz-$K" "/boot/initramfs-$K.img"
args() { grubby --info=ALL 2>/dev/null | sed -n 's/^args=//p'; }
state() { sed -n "s/^$1=//p" /var/lib/machman/state.env 2>/dev/null; }

$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/run1.log 2>&1
args | grep -q 'console=hvc1 console=tty0' && [ "$(state KERNEL_CONSOLE_METHOD)" = "'grubby'" ] \
	|| R KC_STATE_KEPT uncalibrated
# A later run for something else keeps the kernel console's record…
$SH "$S" -y --user reg --ssh --no-console --no-install --no-service >/tmp/run2.log 2>&1
if [ "$(state KERNEL_CONSOLE)" = "'hvc1'" ] && [ "$(state KERNEL_CONSOLE_METHOD)" = "'grubby'" ]
then
	R KC_STATE_KEPT pass
else
	R KC_STATE_KEPT fail; cat /var/lib/machman/state.env
fi
# …so the uninstall takes grubby's path, not /etc/default/grub's.
$SH "$S" --uninstall -y >/tmp/unin.log 2>&1
if ! args | grep -q 'console=hvc1'; then R KC_GRUBBY_UNINSTALL pass; else
	R KC_GRUBBY_UNINSTALL fail; args; tail -n 3 /tmp/unin.log; fi
exit 0
