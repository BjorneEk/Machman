# OpenRC guests (Alpine): clone doctrine, sshfs boot script, boot hook, report-only hygiene.
# The seeded artifacts mirror a guest whose disk was cloned from another Machman VM (the
# source's marker on every machman artifact).
# CHECKS: CLONE_NOTE CLONE_SWEPT CLONE_REVERSE REPORT_SSH SSHFS_SPACE SSHFS_BOOT_OPTS
# CHECKS: IDEMPOTENT_ALPINE HOOK_INSTALLED FSTAB_VERIFY_ALPINE REPORT_ONLY_CLEAN HOOK_REMOVED
# CHECKS: FSTAB_CLEAN STATE_REMOVED_ALPINE BOOT_HOOK_LOCAL LOOKALIKE_KEPT
. /mnt/machman/share/regress/lib.sh
# Machman markers are always 12 hex chars — the sweep matches exactly that shape.
OLD=machman-0ddc105e9999
BOOT=/etc/local.d/machman-sshfs.start

mkuser reg
mkdir -p /home/reg/.ssh /var/lib/machman
# The user's own key whose comment merely contains machman- (S39) is never swept.
printf '%s\n%s\n%s\n' "ssh-rsa USERSOWNKEY user@laptop" \
	"ssh-ed25519 AAAA_LOOKALIKE bob@machman-debian" \
	"ssh-ed25519 AAAA_OLDBLOB $OLD source-vm" > /home/reg/.ssh/authorized_keys
printf 'ssh-ed25519 AAAA_OLDREV %s-reverse\n' "$OLD" > /home/reg/.ssh/machman_host.pub
touch /home/reg/.ssh/machman_host
printf "STATE_VERSION=1\nSCRIPT_VERSION=3\nMARKER='%s'\nCONFIGURED='ssh'\n" "$OLD" \
	> /var/lib/machman/state.env

$SH "$S" -y --user reg --two-way --automount-sshfs --no-install --no-service \
	>/tmp/run1.log 2>&1
if grep -q 'treating it as new' /tmp/run1.log; then R CLONE_NOTE pass; else
	R CLONE_NOTE fail; fi
if [ "$(grep -c ' machman-' /home/reg/.ssh/authorized_keys)" = 1 ] \
	&& grep -q "$NEW" /home/reg/.ssh/authorized_keys \
	&& ! grep -q "$OLD" /home/reg/.ssh/authorized_keys \
	&& grep -q USERSOWNKEY /home/reg/.ssh/authorized_keys; then
	R CLONE_SWEPT pass
else
	R CLONE_SWEPT fail; cat /home/reg/.ssh/authorized_keys
fi
if grep -q 'AAAA_LOOKALIKE bob@machman-debian' /home/reg/.ssh/authorized_keys; then
	R LOOKALIKE_KEPT pass; else R LOOKALIKE_KEPT fail; fi
if grep -q "$NEW-reverse" /home/reg/.ssh/machman_host.pub; then R CLONE_REVERSE pass; else
	R CLONE_REVERSE fail; fi
if grep -q '^FEATURE_ssh=configured reg' "$REPORT"; then
	R REPORT_SSH pass; else R REPORT_SSH fail; fi

# Space-bearing host paths survive into the boot script and the report — the share
# always lives under "Application Support", so a first-space split breaks every guest.
if grep -qF ":/Users/g/My Docs' '/mnt/machman/mounts/docs'" "$BOOT" 2>/dev/null \
	&& grep -qF "sshfs docs /mnt/machman/mounts/docs" "$REPORT"; then
	R SSHFS_SPACE pass
else
	R SSHFS_SPACE fail
	grep -n sshfs "$BOOT" 2>/dev/null | head -4
	grep -n AUTOMOUNT "$REPORT" | head -4
fi
# Boot-script mounts carry only ssh/sshfs-valid options (nofail/_netdev are fstab words —
# libfuse refuses the whole mount over them), the ABSOLUTE sshfs path (FreeBSD's rc PATH
# lacks /usr/local/bin), and BatchMode so a refused key fails fast.
if grep -q "BatchMode=yes" "$BOOT" 2>/dev/null && ! grep -q "nofail" "$BOOT" \
	&& grep -qE "^'/[a-z/]+/sshfs' -o" "$BOOT"; then
	R SSHFS_BOOT_OPTS pass
else
	R SSHFS_BOOT_OPTS fail; grep -n "sshfs" "$BOOT" 2>/dev/null | head -2
fi

etcsum /etc > /tmp/sum-1
$SH "$S" -y --user reg --two-way --automount-sshfs --no-install --no-service \
	>/tmp/run2.log 2>&1
etcsum /etc > /tmp/sum-2
if cmp -s /tmp/sum-1 /tmp/sum-2; then R IDEMPOTENT_ALPINE pass; else
	R IDEMPOTENT_ALPINE fail; diff /tmp/sum-1 /tmp/sum-2 | head -10
fi
if [ -x /etc/local.d/machman-report.start ]; then R HOOK_INSTALLED pass; else
	R HOOK_INSTALLED fail; fi
findmnt --verify --tab-file /etc/fstab >/tmp/fstab.log 2>&1
if grep -qiE '\[E\]|parse error' /tmp/fstab.log; then
	R FSTAB_VERIFY_ALPINE fail; cat /tmp/fstab.log; else R FSTAB_VERIFY_ALPINE pass; fi

# --report-only: the report is rewritten, nothing else moves.
cp /var/lib/machman/state.env /tmp/state-before
O="$(stat -c %Y "$REPORT")"
sleep 1
$SH "$S" --report-only -q >/tmp/ro.log 2>&1
etcsum /etc > /tmp/sum-3
N="$(stat -c %Y "$REPORT")"
if [ "$N" != "$O" ] && cmp -s /tmp/sum-2 /tmp/sum-3 \
	&& cmp -s /tmp/state-before /var/lib/machman/state.env; then
	R REPORT_ONLY_CLEAN pass
else
	R REPORT_ONLY_CLEAN fail
fi

# S27: the local.d hook runs the guest's own copy (in the background), which refreshes the
# report with the installer unserved (GuestSetup moved away).
HOOK=/etc/local.d/machman-report.start
mv /mnt/machman/share/GuestSetup /mnt/machman/share/GuestSetup.unserved
rm -f "$REPORT"
sh "$HOOK"
n=0
while { [ ! -f "$REPORT" ] || pgrep -f 'report[.]sh' >/dev/null; } && [ "$n" -lt 30 ]; do
	sleep 1
	n=$((n + 1))
done
mv /mnt/machman/share/GuestSetup.unserved /mnt/machman/share/GuestSetup
if grep -q '/var/lib/machman/report.sh' "$HOOK" && ! grep -q GuestSetup "$HOOK" \
	&& grep -q '^STATUS=' "$REPORT" 2>/dev/null; then
	R BOOT_HOOK_LOCAL pass
else
	R BOOT_HOOK_LOCAL fail; cat "$HOOK"; ls -l /var/lib/machman
fi

$SH "$S" --uninstall -y >/tmp/unin.log 2>&1
if [ ! -e /etc/local.d/machman-report.start ]; then R HOOK_REMOVED pass; else
	R HOOK_REMOVED fail; fi
if ! grep -q machman /etc/fstab 2>/dev/null; then R FSTAB_CLEAN pass; else
	R FSTAB_CLEAN fail; grep machman /etc/fstab; fi
if [ ! -f /var/lib/machman/state.env ]; then R STATE_REMOVED_ALPINE pass; else
	R STATE_REMOVED_ALPINE fail; fi
exit 0
