# systemd guests (sd_booted faked): grub kernel-console edits, fstab, idempotency, plan
# verbs, uninstall restore. The distro's own grub tool does the rebuild (it fails in a
# container; the edit, its backup and its idempotency are what is checked).
# CHECKS: IDEMPOTENT TTY0_LAST GRUB_SOURCES GRUB_BACKUP FSTAB_VERIFY SECOND_PLAN_CLEAN
# CHECKS: UNINSTALL_PRISTINE STATE_REMOVED BOOT_COPY BOOT_COPY_REMOVED UNIT_AFTER_NETWORK
. /mnt/machman/share/regress/lib.sh

printf 'GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > /etc/default/grub
# Every installed guest has an fstab; some container bases ship none.
[ -f /etc/fstab ] || : > /etc/fstab
mkdir -p /boot/grub /boot/grub2 && touch /boot/grub/grub.cfg /boot/grub2/grub.cfg
fake_systemd
mkuser reg
etcsum /etc > /tmp/sum-base

# Calibrate the verb check: a FRESH plan must show install verbs…
$SH "$S" -n -y --user reg --no-console --no-install --no-service >/tmp/plan-fresh.log 2>&1
grep -Eq 'install \(|install:' /tmp/plan-fresh.log || R SECOND_PLAN_CLEAN uncalibrated

$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/run1.log 2>&1
etcsum /etc > /tmp/sum-1
$SH "$S" -y --user reg --kernel-console=hvc1 --no-install --no-service >/tmp/run2.log 2>&1
etcsum /etc > /tmp/sum-2

if cmp -s /tmp/sum-1 /tmp/sum-2; then R IDEMPOTENT pass; else
	R IDEMPOTENT fail; diff /tmp/sum-1 /tmp/sum-2 | head -10
fi
if grep -q 'console=hvc1 console=tty0" # machman-' /etc/default/grub; then
	R TTY0_LAST pass; else R TTY0_LAST fail; tail -n 3 /tmp/run1.log; fi
if (. /etc/default/grub) 2>/dev/null; then R GRUB_SOURCES pass; else R GRUB_SOURCES fail; fi
if [ -f /boot/grub/grub.cfg.machman-backup ] || [ -f /boot/grub2/grub.cfg.machman-backup ]
then R GRUB_BACKUP pass; else R GRUB_BACKUP fail; fi
findmnt --verify --tab-file /etc/fstab >/tmp/fstab.log 2>&1
if grep -qiE '\[E\]|parse error' /tmp/fstab.log; then
	R FSTAB_VERIFY fail; cat /tmp/fstab.log; else R FSTAB_VERIFY pass; fi

# …and a plan over a CONFIGURED guest must not (consoles excluded: the devices do not
# exist in a container, so their rows would re-plan install forever).
$SH "$S" -n -y --user reg --no-console --no-install --no-service >/tmp/plan2.log 2>&1
if grep -Eq 'install \(|install:' /tmp/plan2.log; then
	R SECOND_PLAN_CLEAN fail; grep -E 'install \(|install:' /tmp/plan2.log
else
	R SECOND_PLAN_CLEAN pass
fi

# S27: the boot hook runs the guest's own copy of the script beside the state, never the
# share — so it refreshes the report with the installer unserved (GuestSetup moved away).
UNIT=/etc/systemd/system/machman-report.service
COPY=/var/lib/machman/report.sh
exec_line="$(sed -n 's/^ExecStart=//p' "$UNIT" 2>/dev/null)"
boot="fail (hook)"
case "$exec_line" in
"/bin/sh $COPY "*)
	if ! grep -q GuestSetup "$UNIT" && [ "$(meta "$COPY" | cut -d' ' -f1)" = -rwx------ ] \
		&& grep -qx "BOOT_REPORT_DIR='/mnt/machman/share/GuestReport'" \
			/var/lib/machman/machman.env; then
		mv /mnt/machman/share/GuestSetup /mnt/machman/share/GuestSetup.unserved
		rm -f "$REPORT"
		sh -c "$exec_line" >/tmp/boot.log 2>&1
		boot="fail (no report)"
		grep -q '^STATUS=' "$REPORT" 2>/dev/null && boot=pass
		mv /mnt/machman/share/GuestSetup.unserved /mnt/machman/share/GuestSetup
	fi
	;;
esac
R BOOT_COPY "$boot"
[ "$boot" = pass ] || { cat "$UNIT"; ls -l /var/lib/machman; tail -n 3 /tmp/boot.log; }
# S31: it runs once the network is up, without holding boot while it waits (--at-boot).
if grep -qx 'Wants=network-online.target' "$UNIT" \
	&& grep -qx 'After=local-fs.target remote-fs.target network-online.target' "$UNIT" \
	&& grep -qx 'Type=simple' "$UNIT" && [ "$exec_line" = "/bin/sh $COPY --at-boot -q" ]
then R UNIT_AFTER_NETWORK pass; else R UNIT_AFTER_NETWORK fail; cat "$UNIT"; fi

$SH "$S" --uninstall -y >/tmp/unin.log 2>&1
# sshd host keys appear under /etc/ssh (ssh-keygen -A) and stay — everything else is ours.
etcsum /etc | grep -v '^[0-9a-f]*  ./ssh/' > /tmp/sum-after
grep -v '^[0-9a-f]*  ./ssh/' /tmp/sum-base > /tmp/sum-base-f
if cmp -s /tmp/sum-base-f /tmp/sum-after; then R UNINSTALL_PRISTINE pass; else
	R UNINSTALL_PRISTINE fail; diff /tmp/sum-base-f /tmp/sum-after | head -10
	tail -n 3 /tmp/unin.log
fi
if [ ! -f /var/lib/machman/state.env ]; then R STATE_REMOVED pass; else
	R STATE_REMOVED fail; fi
if [ ! -e /var/lib/machman ]; then R BOOT_COPY_REMOVED pass; else
	R BOOT_COPY_REMOVED fail; ls -la /var/lib/machman; fi
exit 0
