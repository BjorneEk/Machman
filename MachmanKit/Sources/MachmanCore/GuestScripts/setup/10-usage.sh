# === machman-setup: 10-usage ===

usage() {
	cat <<USAGE
Machman guest setup for "$VM_NAME" (script v$SCRIPT_VERSION)

usage: sh install.sh [options]
       sh install.sh --uninstall [--user <name>]

Who
  --user <name>          set SSH up for this user (default: the invoking user)
What                     (default: ask per feature; every --x has a --no-x)
  --console              login prompts on this VM's consoles
  --consoles "<list>"    exactly these console devices (e.g. "hvc0 hvc1")
  --kernel-console[=dev] send kernel boot messages to a console (default: the first).
                         WARNING: EDITS THE BOOT LOADER. Never offered interactively —
                         only this flag enables it. The display is kept on tty0 and
                         grub.cfg is backed up, but treat it as a reachable-for-repair
                         change: test in a Machman safe run first.
  --ssh                  Mac -> guest SSH (enable sshd, install the Mac's key)
  --two-way              also configure guest -> host SSH   (--one-way skips it)
  --sshfs                install sshfs in the guest (implies --two-way)
  --mount-setup          let ANY user of the guest mount filesystems
                         (vfs.usermount=1; root can mount without it)
  --automount-virtiofs   mount the Machman share at boot (fstab)
  --automount-sshfs      mount sshfs host folders at boot (needs guest -> host SSH)
  --mountpoint <path>    where sshfs host folders land (default $MOUNT_ROOT)
  --install              install missing packages with this guest's package manager
  --pm <name>            force the package manager (apt, dnf, yum, zypper, pacman, apk,
                         xbps, emerge, pkg, pkg_add)
  --no-service           install the SSH key only; do not touch services
How
  -y, --yes              never ask; take the defaults shown by --dry-run
  -n, --dry-run          print the plan and exit; change nothing
      --report-only      probe and refresh Machman's report; change nothing else.
                         A boot hook installed with the setup runs this at every
                         boot, so "next boot" states flip once the guest reboots.
  -v, --verbose          narrate every decision and command
  -q, --quiet            only the summary and errors
  -h, --help             this text
      --version          print the script version
      --uninstall        remove everything this script installed

Exit codes: 0 done, 3 refused before touching anything, 4 partial (see the report),
1 a step failed, 64 bad usage.
USAGE
}
