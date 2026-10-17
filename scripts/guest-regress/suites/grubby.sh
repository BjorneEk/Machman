# grubby (BLS: Fedora/RHEL): the kernel console's arguments land in every boot entry and
# leave them at uninstall — also after a later run for other features, which keeps the
# record the uninstall needs; without that record the uninstall names what it finds and
# leaves it. The boot entry is fabricated (a container has no /boot).
# CHECKS: KC_STATE_KEPT KC_GRUBBY_UNINSTALL KC_GRUBBY_NO_STATE KC_GRUBBY_KEEPS_PRIOR
# CHECKS: KC_GRUBBY_PER_ENTRY
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

# S11: the state is gone (a failed write, a cloned guest): the pair is named with grubby's
# remedy, left in place, and the uninstall ends partial.
$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/run3.log 2>&1
rm -f /var/lib/machman/state.env
$SH "$S" --uninstall -y >/tmp/unin2.log 2>&1
rc=$?
# The script folds its lines to the terminal: read them back unfolded.
tr -d '\n' < /tmp/unin2.log > /tmp/unin2.flat
if [ "$rc" -eq 4 ] && grep -q 'console=hvc1 console=tty0 stays in the boot entries' /tmp/unin2.flat \
	&& grep -qF "grubby --update-kernel=ALL --remove-args='console=hvc1 console=tty0'" \
		/tmp/unin2.flat \
	&& args | grep -q 'console=hvc1 console=tty0'; then
	R KC_GRUBBY_NO_STATE pass
else
	R KC_GRUBBY_NO_STATE "fail (exit $rc)"; tail -n 4 /tmp/unin2.log
fi

# S60: console= arguments the entry had before setup — grubby's add replaces them — come
# back at the uninstall, in their order, and the uninstall takes only what the run added.
E="/boot/loader/entries/$(cat /etc/machine-id)-$K.conf"
sed -i 's/^options .*/options root=UUID=1234 ro console=ttyS0,115200 console=tty0 quiet/' "$E"
before="$(args)"
$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/run4.log 2>&1
during="$(args)"
$SH "$S" --uninstall -y >/tmp/unin4.log 2>&1
consoles() { printf '%s\n' "$1" | tr -d '"' | tr ' ' '\n' | grep '^console=' | tr '\n' ' '; }
if [ "$(consoles "$(args)")" = "$(consoles "$before")" ] \
	&& printf '%s' "$during" | grep -q 'console=hvc1 console=tty0'; then
	R KC_GRUBBY_KEEPS_PRIOR pass
else
	R KC_GRUBBY_KEEPS_PRIOR fail; echo "before $before"; echo "during $during"; args
	tail -n 4 /tmp/unin4.log
fi

# …and only into the entry that lost them: a rescue entry without console= arguments
# gets none back (setup's go from it too).
R0="/boot/loader/entries/$(cat /etc/machine-id)-0-rescue.conf"
printf 'title Rescue\nversion 0-rescue\nlinux /vmlinuz-0-rescue\n' > "$R0"
printf 'options root=UUID=1234 ro\n' >> "$R0"
touch /boot/vmlinuz-0-rescue
sed -i 's/^options .*/options root=UUID=1234 ro console=ttyS0,115200 console=tty0 quiet/' "$E"
$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/run5.log 2>&1
$SH "$S" --uninstall -y >/tmp/unin5.log 2>&1
rescue="$(grubby --info=/boot/vmlinuz-0-rescue 2>/dev/null | sed -n 's/^args=//p')"
main="$(grubby --info=/boot/vmlinuz-$K 2>/dev/null | sed -n 's/^args=//p')"
if [ "$(consoles "$rescue")" = "" ] && [ "$(consoles "$main")" = "$(consoles "$before")" ]; then
	R KC_GRUBBY_PER_ENTRY pass
else
	R KC_GRUBBY_PER_ENTRY fail; echo "rescue $rescue"; echo "main $main"; tail -n 4 /tmp/unin5.log
fi
exit 0
