# A NixOS stand-in: os-release says nixos, /etc/fstab and /etc/systemd/system are links
# into a read-only /nix/store (run.sh mounts one), configuration.nix is the stock template
# and nixos-rebuild only records that it ran. Declarative pieces must be reported, never
# written, and never abort the run.
# CHECKS: NIXOS_NO_ABORT NIXOS_AUTOMOUNT_DECLARATIVE NIXOS_SSHD_ADDED NIXOS_PLAN_DECLARATIVE
# CHECKS: NIXOS_ONLY_MARKER
. /mnt/machman/share/regress/lib.sh

fake_systemd
mkuser reg
rm -f /etc/os-release && printf 'ID=nixos\nNAME=NixOS\nVERSION_ID="25.05"\n' > /etc/os-release
rm -rf /etc/fstab /etc/systemd/system
mkdir -p /etc/systemd
ln -s /nix/store/fstab /etc/fstab
ln -s /nix/store/systemd-system /etc/systemd/system
mkdir -p /etc/nixos
cat > /etc/nixos/configuration.nix <<'NIX'
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  system.stateVersion = "25.05";
}
NIX
cp /etc/nixos/configuration.nix /tmp/configuration.nix.orig
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> /tmp/rebuild.log\nexit 0\n' \
	> /usr/local/bin/nixos-rebuild
chmod 755 /usr/local/bin/nixos-rebuild

$SH "$S" -y --user reg --automount-virtiofs --automount-sshfs --two-way --no-install \
	--no-service >/tmp/run1.log 2>&1
rc=$?
if [ "$rc" -ne 1 ] && ! grep -q '^STATUS=failed' "$REPORT"; then R NIXOS_NO_ABORT pass; else
	R NIXOS_NO_ABORT "fail (exit $rc)"; tail -n 4 /tmp/run1.log; fi
if grep -q '^FEATURE_virtiofsAutomount=unavailable .*NixOS' "$REPORT" \
	&& grep -q '^FEATURE_sshfsAutomount=unavailable .*NixOS' "$REPORT"; then
	R NIXOS_AUTOMOUNT_DECLARATIVE pass
else
	R NIXOS_AUTOMOUNT_DECLARATIVE fail; grep '^FEATURE_' "$REPORT"
fi

# Stock configuration.nix (its only openssh mention is the commented template line):
# --install adds the marked line inside the final brace and rebuilds.
$SH "$S" -y --user reg --ssh --install --no-automount-virtiofs --no-automount-sshfs \
	--one-way --no-sshfs >/tmp/run2.log 2>&1
if grep -q "^  services.openssh.enable = true; # $NEW\$" /etc/nixos/configuration.nix \
	&& [ "$(tail -n 1 /etc/nixos/configuration.nix)" = "}" ] \
	&& grep -q switch /tmp/rebuild.log 2>/dev/null; then
	R NIXOS_SSHD_ADDED pass
else
	R NIXOS_SSHD_ADDED fail; tail -n 4 /tmp/run2.log; cat /etc/nixos/configuration.nix
fi

# The openssh package is on PATH even while the service is off: the plan is still the
# declarative one, never "enable and start".
cp /tmp/configuration.nix.orig /etc/nixos/configuration.nix
mkdir -p /usr/local/sbin
printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/sshd && chmod 755 /usr/local/sbin/sshd
$SH "$S" -n -y --user reg --ssh --no-automount-virtiofs --no-automount-sshfs --one-way \
	--no-sshfs >/tmp/plan.log 2>&1
if grep -q 'ssh server .*\(declarative\|NixOS\)' /tmp/plan.log \
	&& ! grep -q 'enable and start' /tmp/plan.log; then
	R NIXOS_PLAN_DECLARATIVE pass
else
	R NIXOS_PLAN_DECLARATIVE fail; grep 'ssh server' /tmp/plan.log
fi

# A configuration.nix holding nothing but Machman's line still uninstalls.
printf '  services.openssh.enable = true; # %s\n' "$NEW" > /etc/nixos/configuration.nix
$SH "$S" --uninstall -y >/tmp/unin.log 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s /etc/nixos/configuration.nix ] \
	&& [ -z "$(find /etc/nixos -name '*machman*' ! -name '*.machman-backup')" ]; then
	R NIXOS_ONLY_MARKER pass
else
	R NIXOS_ONLY_MARKER "fail (exit $rc)"; ls -la /etc/nixos; tail -n 3 /tmp/unin.log
fi
exit 0
