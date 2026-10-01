# Root edits files other users own (~/.ssh, the sshfs mount root, the report drop-box):
# nothing a user plants there may redirect a root write, and a user's own files keep their
# owner and mode. Every victim is a root-owned file or directory under /etc.
# CHECKS: SSH_TMP_LINK SSH_UNMARKED_KEPT SSH_CONFIG_KEPT UNINSTALL_KEPT_LINK
# CHECKS: AUTHKEYS_TMP_LINK AUTHKEYS_KEPT SSH_DIR_LINK AUTHKEYS_LINK REVERSE_KEY_LINK
# CHECKS: KNOWN_HOSTS_LINK MOUNT_DIR_LINK REPORT_TMP_LINK EDIT_LINK_SWAP
. /mnt/machman/share/regress/lib.sh

[ -f /etc/fstab ] || : > /etc/fstab
# The systemd-only distros ship a systemctl that needs systemd as PID 1, as their guests
# always have it: stand in for it there.
if command -v systemctl >/dev/null 2>&1; then fake_systemd; fi
victim() { # <path> — a root-owned file whose content and owner must survive
	printf 'root-only %s\n' "$1" > "$1"
	chmod 600 "$1"
}
intact() { # <path>
	[ "$(cat "$1" 2>/dev/null)" = "root-only $1" ] && [ "$(meta "$1")" = "-rw------- 0 0" ]
}
plant() { # <user> <link> <target> — the user's own link in the user's own directory
	ln -s "$3" "$2"
	chown -h "$1:$1" "$2" 2>/dev/null || chown -h "$1" "$2"
}
asuser() { # <user> <cmd…> — create the user's files as the user would
	_u="$1"; shift
	"$@"
	chown -R "$_u:$(id -gn "$_u")" "/home/$_u/.ssh"
}

# reg is set up (Mac -> guest and guest -> host); eve only lives here.
mkuser reg
mkuser eve
mkdir -p /home/reg/.ssh /home/eve/.ssh
printf 'Host github\n\tUser git\n' > /home/reg/.ssh/config
printf 'ssh-rsa REGSOWNKEY reg@laptop\n' > /home/reg/.ssh/authorized_keys
asuser reg chmod 600 /home/reg/.ssh/config
asuser reg chmod 644 /home/reg/.ssh/authorized_keys
printf 'Host *\n\tServerAliveInterval 30\n' > /home/eve/.ssh/config
asuser eve chmod 640 /home/eve/.ssh/config
cp -p /home/reg/.ssh/config /tmp/reg-config.orig
cp -p /home/eve/.ssh/config /tmp/eve-config.orig
eve_inode="$(ls -i /home/eve/.ssh/config | awk '{ print $1 }')"
victim /etc/machman-victim-config
victim /etc/machman-victim-keys
victim /etc/machman-victim-report
victim /etc/machman-victim-known
victim /etc/machman-victim-keys2
printf 'ssh-ed25519 AAAA_HOSTMACHINE root@mac\n' \
	> /mnt/machman/share/GuestSetup/host_machine_key.pub

$SH "$S" -y --user reg --ssh --two-way --no-install --no-service >/tmp/run1.log 2>&1
# Install leaves authorized_keys as sshd wants it (reg's, 0600); reg then picks 0640.
chmod 640 /home/reg/.ssh/authorized_keys
# The old fixed temp names, planted as links before the uninstall sweeps every home.
plant eve /home/eve/.ssh/config.machman-tmp /etc/machman-victim-config
plant reg /home/reg/.ssh/authorized_keys.machman-tmp /etc/machman-victim-keys
# A dotfile-managed config (a link into dot's own repo) that carries our block.
mkuser dot
mkdir -p /home/dot/.ssh /home/dot/dotfiles
printf 'Host x\n# BEGIN %s\nHost mac\n# END %s\n' "$NEW" "$NEW" > /home/dot/dotfiles/ssh_config
cp /home/dot/dotfiles/ssh_config /tmp/dot-config.orig
chown -R dot /home/dot/.ssh /home/dot/dotfiles
plant dot /home/dot/.ssh/config /home/dot/dotfiles/ssh_config
$SH "$S" --uninstall -y >/tmp/unin.log 2>&1
unin_rc=$?

if intact /etc/machman-victim-config; then R SSH_TMP_LINK pass; else
	R SSH_TMP_LINK fail; meta /etc/machman-victim-config; fi
if [ ! -L /home/eve/.ssh/config ] && cmp -s /tmp/eve-config.orig /home/eve/.ssh/config \
	&& [ "$(meta /home/eve/.ssh/config)" = "$(meta /tmp/eve-config.orig)" ] \
	&& [ "$(ls -i /home/eve/.ssh/config | awk '{ print $1 }')" = "$eve_inode" ]; then
	R SSH_UNMARKED_KEPT pass
else
	R SSH_UNMARKED_KEPT fail; ls -lin /home/eve/.ssh/
fi
if cmp -s /tmp/reg-config.orig /home/reg/.ssh/config \
	&& [ "$(meta /home/reg/.ssh/config)" = "$(meta /tmp/reg-config.orig)" ]; then
	R SSH_CONFIG_KEPT pass
else
	R SSH_CONFIG_KEPT fail; ls -ln /home/reg/.ssh/config; cat /home/reg/.ssh/config
fi
# The uninstall leaves dot's link and its target alone, names it, finishes the rest and
# ends partial.
if [ "$unin_rc" -eq 4 ] && [ -L /home/dot/.ssh/config ] \
	&& cmp -s /tmp/dot-config.orig /home/dot/dotfiles/ssh_config \
	&& grep -q 'is a symbolic link' /tmp/unin.log \
	&& grep -q 'gone except where noted above' /tmp/unin.log \
	&& [ ! -f /var/lib/machman/state.env ]; then
	R UNINSTALL_KEPT_LINK pass
else
	R UNINSTALL_KEPT_LINK "fail (exit $unin_rc)"; ls -ln /home/dot/.ssh; tail -n 4 /tmp/unin.log
fi
if intact /etc/machman-victim-keys; then R AUTHKEYS_TMP_LINK pass; else
	R AUTHKEYS_TMP_LINK fail; meta /etc/machman-victim-keys; fi
reg_ids="$(id -u reg) $(id -g reg)"
if [ "$(meta /home/reg/.ssh/authorized_keys)" = "-rw-r----- $reg_ids" ] \
	&& [ "$(cat /home/reg/.ssh/authorized_keys)" = "ssh-rsa REGSOWNKEY reg@laptop" ]; then
	R AUTHKEYS_KEPT pass
else
	R AUTHKEYS_KEPT fail; ls -ln /home/reg/.ssh/authorized_keys
fi

# A user being set up plants links where root is about to write.
mkuser mal
mkdir -p /etc/machman-trap && chmod 755 /etc/machman-trap
plant mal /home/mal/.ssh /etc/machman-trap
$SH "$S" -y --user mal --ssh --two-way --no-install --no-service >/tmp/mal.log 2>&1
if [ "$(meta /etc/machman-trap | cut -d' ' -f2-)" = "0 0" ] \
	&& [ -z "$(ls -A /etc/machman-trap)" ]; then
	R SSH_DIR_LINK pass
else
	R SSH_DIR_LINK fail; ls -lan /etc/machman-trap; tail -n 3 /tmp/mal.log
fi

mkuser lnk
mkdir -p /home/lnk/.ssh && chown lnk /home/lnk/.ssh
plant lnk /home/lnk/.ssh/authorized_keys /etc/machman-victim-keys2
plant lnk /home/lnk/.ssh/machman_host /etc/machman-keytrap
plant lnk /home/lnk/.ssh/machman_known_hosts /etc/machman-victim-known
$SH "$S" -y --user lnk --ssh --two-way --no-install --no-service >/tmp/lnk.log 2>&1
if intact /etc/machman-victim-keys2; then R AUTHKEYS_LINK pass; else
	R AUTHKEYS_LINK fail; meta /etc/machman-victim-keys2; fi
if [ ! -e /etc/machman-keytrap ] \
	|| [ "$(meta /etc/machman-keytrap | cut -d' ' -f2-)" = "0 0" ]; then
	R REVERSE_KEY_LINK pass
else
	R REVERSE_KEY_LINK fail; meta /etc/machman-keytrap
fi
if intact /etc/machman-victim-known; then R KNOWN_HOSTS_LINK pass; else
	R KNOWN_HOSTS_LINK fail; meta /etc/machman-victim-known; fi

# The sshfs mount root belongs to the user; a mount's directory there may be a link.
mkuser mnt
mkdir -p /mnt/machman/mounts /etc/machman-mtrap
chown mnt /mnt/machman/mounts
plant mnt /mnt/machman/mounts/docs /etc/machman-mtrap
$SH "$S" -y --user mnt --automount-sshfs --no-install --no-service >/tmp/mnt.log 2>&1
if [ "$(meta /etc/machman-mtrap | cut -d' ' -f2-)" = "0 0" ]; then R MOUNT_DIR_LINK pass
else R MOUNT_DIR_LINK fail; meta /etc/machman-mtrap; fi

# The report drop-box is writable by whoever mounted the share (sshfs bootstrap, macOS).
ln -s /etc/machman-victim-report /mnt/machman/share/GuestReport/report.env.tmp
$SH "$S" --report-only -q >/tmp/ro.log 2>&1
if intact /etc/machman-victim-report; then R REPORT_TMP_LINK pass; else
	R REPORT_TMP_LINK fail; meta /etc/machman-victim-report; fi

# A user swaps their file for a link to a root-only one after the edit's not-a-link check
# (inside the temp-name od call, which runs in that window): the edit reads through one
# open checked against the checked file, so it refuses instead of copying the victim in.
mkuser swp
mkdir -p /home/swp/.ssh
printf 'mine\n# BEGIN %s\nours\n# END %s\n' "$NEW" "$NEW" > /home/swp/.ssh/config
chown -R swp /home/swp/.ssh
victim /etc/machman-victim-swap
cat > /tmp/swap.sh <<EOF
set -eu
. /mnt/machman/share/regress/05-lib.sh
MARKER='$NEW'
od() {
	rm -f /home/swp/.ssh/config && ln -s /etc/machman-victim-swap /home/swp/.ssh/config
	chown -h swp /home/swp/.ssh/config
	command od "\$@"
}
strip_block /home/swp/.ssh/config && echo copied || echo "kept: \$R_ERROR"
EOF
swap_out="$($SH /tmp/swap.sh 2>&1)"
if intact /etc/machman-victim-swap && [ -L /home/swp/.ssh/config ] \
	&& [ "$swap_out" = "kept: /home/swp/.ssh/config changed while it was being edited" ]; then
	R EDIT_LINK_SWAP pass
else
	R EDIT_LINK_SWAP fail; printf '%s\n' "$swap_out"; ls -ln /home/swp/.ssh
fi
exit 0
