# A NixOS stand-in: os-release says nixos, /etc/fstab and /etc/systemd/system are links
# into a read-only /nix/store (run.sh mounts one), configuration.nix is the stock template
# and nixos-rebuild only records that it ran. Declarative pieces must be reported, never
# written, and never abort the run.
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
