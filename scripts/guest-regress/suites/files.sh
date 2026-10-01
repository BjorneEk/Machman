# Root edits files other users own (~/.ssh, the sshfs mount root, the report drop-box):
# nothing a user plants there may redirect a root write, and a user's own files keep their
# owner and mode. Every victim is a root-owned file or directory under /etc.
# CHECKS: SSH_TMP_LINK SSH_UNMARKED_KEPT SSH_CONFIG_KEPT UNINSTALL_KEPT_LINK
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
asuser reg chmod 600 /home/reg/.ssh/config
printf 'Host *\n\tServerAliveInterval 30\n' > /home/eve/.ssh/config
asuser eve chmod 640 /home/eve/.ssh/config
cp -p /home/reg/.ssh/config /tmp/reg-config.orig
cp -p /home/eve/.ssh/config /tmp/eve-config.orig
eve_inode="$(ls -i /home/eve/.ssh/config | awk '{ print $1 }')"
victim /etc/machman-victim-config

$SH "$S" -y --user reg --ssh --two-way --no-install --no-service >/tmp/run1.log 2>&1
# The old fixed temp name, planted as a link before the uninstall sweeps every home.
plant eve /home/eve/.ssh/config.machman-tmp /etc/machman-victim-config
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
exit 0
