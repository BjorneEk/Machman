# === machman-setup: 20-detect ===
# Shared detection: guest OS/family, init system, package manager, user, sshd, transport,
# sshfs, addresses — plus the console/bootloader probes the console features build on.
# Detection never mutates and never fails: unknowns become reported facts, not exits.

OS=""
OS_FAMILY=""
OS_ID=""
OS_VERSION=""
INIT="unknown"
PM=""
PM_NAME=""
U=""
HOME_DIR=""
GROUP=""
SSHD="missing"
SSHD_UNIT="sshd"
TRANSPORT="local"
SSHFS=0
SSHFS_VERSION=""
SSHFS_MOUNT_OK=0
FUSE_PERSISTED=0
IP=""
GATEWAY=""
GUEST_HOST_KEY=""
REVERSE_PUBKEY=""
VIRTIOFS_OK=0
BOOTLOADER="none"          # grubby | update-grub | grub-mkconfig | grub2-mkconfig |
                           # systemd-boot | kernel-cmdline | none
CMDLINE_CONSOLES=""        # console= devices from /proc/cmdline, space-separated

os_release() {
	[ -r /etc/os-release ] || return 0
	sed -n "s/^$1=//p" /etc/os-release | head -n 1 | tr -d "\"'"
}

has_word() {
	case " $2 " in
	*" $1 "*) return 0 ;;
	*) return 1 ;;
	esac
}

detect_os() {
	OS="$(uname -s)"
	case "$OS" in
	Darwin)
		OS_FAMILY=darwin
		OS_ID=darwin
		OS_VERSION="$(sw_vers -productVersion 2>/dev/null || true)"
		;;
	FreeBSD)
		OS_FAMILY=freebsd
		OS_ID=freebsd
		OS_VERSION="$(uname -r)"
		;;
	OpenBSD)
		OS_FAMILY=openbsd
		OS_ID=openbsd
		OS_VERSION="$(uname -r)"
		;;
	NetBSD)
		OS_FAMILY=netbsd
		OS_ID=netbsd
		OS_VERSION="$(uname -r)"
		;;
	Linux)
		# Parsed, never sourced: /etc/os-release is guest-controlled and we are root.
		OS_ID="$(os_release ID)"
		OS_VERSION="$(os_release VERSION_ID)"
		_do_like="$OS_ID $(os_release ID_LIKE)"
		if [ "$OS_ID" = nixos ]; then OS_FAMILY=nixos
		elif [ "$OS_ID" = alpine ]; then OS_FAMILY=alpine
		elif [ "$OS_ID" = void ]; then OS_FAMILY=void
		elif [ "$OS_ID" = gentoo ]; then OS_FAMILY=gentoo
		elif has_word debian "$_do_like"; then OS_FAMILY=debian
		elif has_word arch "$_do_like"; then OS_FAMILY=arch
		elif has_word rhel "$_do_like" || has_word fedora "$_do_like" \
			|| has_word centos "$_do_like"; then OS_FAMILY=rhel
		elif has_word suse "$_do_like" || has_word opensuse "$_do_like"; then
			OS_FAMILY=suse
		else
			OS_FAMILY=linux-other
		fi
		[ -n "$OS_ID" ] || OS_ID=linux
		;;
	*)
		die 3 "unsupported guest OS: $OS" \
			"Machman's script covers Linux, FreeBSD, OpenBSD, NetBSD and macOS guests."
		;;
	esac
	verbose detect "os=$OS_ID family=$OS_FAMILY version=${OS_VERSION:-?}"
	return 0
}

linux_guest() {
	[ "$OS" = Linux ]
}

detect_init() {
	# sd_booted(3), not `command -v systemctl`: Devuan ships apt without systemd.
	if [ -d /run/systemd/system ]; then INIT=systemd
	elif [ "$OS" = Darwin ]; then INIT=launchd
	elif have rcctl; then INIT=openbsd-rc
	elif have sysrc; then INIT=freebsd-rc
	elif have rc-update && [ -d /etc/runlevels ]; then INIT=openrc
	elif have sv && [ -d /var/service ]; then INIT=runit
	elif [ -f /etc/inittab ]; then INIT=inittab
	elif have service || [ -d /etc/init.d ]; then INIT=sysv
	else INIT=unknown
	fi
	[ "$OS_FAMILY" = debian ] && SSHD_UNIT=ssh
	verbose detect "init=$INIT unit=$SSHD_UNIT"
	return 0
}

# Cheap existence probe for availability checks — detect_pm (which may ask) runs later,
# only once features are selected.
any_pm_present() {
	for _app_bin in apt-get dnf yum zypper pacman apk xbps-install emerge pkg pkg_add; do
		have "$_app_bin" && return 0
	done
	return 1
}

# Which package manager, if any. The family's own is preferred; anything else present is
# offered rather than guessed at.
detect_pm() {
	if [ -n "$PM_OVERRIDE" ]; then
		PM="$PM_OVERRIDE"
		PM_NAME="$PM (forced)"
		return 0
	fi
	_dp_found=""
	for _dp_bin in apt-get dnf yum zypper pacman apk xbps-install emerge pkg pkg_add; do
		if have "$_dp_bin"; then
			_dp_found="$_dp_found
$(pm_id_of "$_dp_bin")"
		fi
	done
	_dp_found="$(printf '%s' "$_dp_found" | sed '/^$/d')"
	[ -n "$_dp_found" ] || { verbose detect "pm=none"; return 0; }
	_dp_pref="$(pm_preferred_for_family)"
	if [ -n "$_dp_pref" ] && printf '%s\n' "$_dp_found" | grep -qx "$_dp_pref"; then
		PM="$_dp_pref"
	elif [ "$(printf '%s\n' "$_dp_found" | wc -l | tr -d ' ')" = "1" ]; then
		PM="$_dp_found"
	else
		menu_select "Which package manager should Machman use?" "$_dp_found" 1
		PM="$R_ITEM"
	fi
	PM_NAME="$PM"
	verbose detect "pm=$PM (found:$(printf '%s' "$_dp_found" | tr '\n' ' '))"
	return 0
}

pm_id_of() {
	case "$1" in
	apt-get) echo apt ;;
	xbps-install) echo xbps ;;
	*) echo "$1" ;;
	esac
}

pm_preferred_for_family() {
	case "$OS_FAMILY" in
	debian) echo apt ;;
	rhel) echo dnf ;;
	suse) echo zypper ;;
	arch) echo pacman ;;
	alpine) echo apk ;;
	void) echo xbps ;;
	gentoo) echo emerge ;;
	freebsd) echo pkg ;;
	openbsd) echo pkg_add ;;
	*) echo "" ;;
	esac
}

pm_command() {
	case "$PM" in
	apt) echo "apt-get install -y" ;;
	dnf) echo "dnf install -y" ;;
	yum) echo "yum install -y" ;;
	zypper) echo "zypper --non-interactive install" ;;
	pacman) echo "pacman -S --noconfirm" ;;
	apk) echo "apk add" ;;
	xbps) echo "xbps-install -y" ;;
	emerge) echo "emerge --quiet" ;;
	pkg) echo "pkg install -y" ;;
	pkg_add) echo "pkg_add" ;;
	*) echo "" ;;
	esac
}

# Package name candidates differ per distro AND per release (openSUSE split openssh in
# 15.6); try them in order rather than betting on one.
pkg_for_sshd() {
	case "$PM" in
	apt|dnf|yum) echo "openssh-server" ;;
	zypper) echo "openssh-server openssh" ;;
	pacman|apk|xbps) echo "openssh" ;;
	emerge) echo "net-misc/openssh" ;;
	*) echo "" ;;
	esac
}

pkg_for_sshfs() {
	case "$PM" in
	apt|pacman|apk|xbps|zypper) echo "sshfs" ;;
	dnf|yum) echo "fuse-sshfs sshfs" ;;
	emerge) echo "net-fs/sshfs" ;;
	pkg) echo "fusefs-sshfs" ;;
	pkg_add) echo "sshfs-fuse" ;;
	*) echo "" ;;
	esac
}

pm_install() {
	_pi_cmd="$(pm_command)"
	[ -n "$_pi_cmd" ] || return 1
	for _pi_pkg in "$@"; do
		# Unquoted on purpose: the command is a fixed word list, not user input.
		# shellcheck disable=SC2086
		if run_live "installing $_pi_pkg" $_pi_cmd "$_pi_pkg"; then
			return 0
		fi
	done
	return 1
}

valid_username() {
	case "$1" in
	""|-*) return 1 ;;
	*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}

candidate_users() {
	case "$OS" in
	Darwin)
		dscl . -list /Users UniqueID 2>/dev/null \
			| awk '$2 >= 501 && $1 !~ /^_/ { print $1 }'
		;;
	*)
		{ getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null || true; } \
			| awk -F: '$3 >= 1000 && $3 < 65000 && $7 !~ /(nologin|false)$/ { print $1 }'
		;;
	esac
}

home_of() {
	case "$OS" in
	Darwin)
		dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }'
		;;
	*)
		_ho_home="$(getent passwd "$1" 2>/dev/null | cut -d: -f6 || true)"
		# No getent on OpenBSD/macOS; id -P speaks master.passwd on the BSDs.
		[ -n "$_ho_home" ] || _ho_home="$(id -P "$1" 2>/dev/null | cut -d: -f9 || true)"
		[ -n "$_ho_home" ] || _ho_home="$(awk -F: -v u="$1" \
			'$1 == u { print $6 }' /etc/passwd 2>/dev/null || true)"
		printf '%s' "$_ho_home"
		;;
	esac
}

detect_user() {
	U="${USER_OVERRIDE:-${SUDO_USER:-${DOAS_USER:-}}}"
	if [ "$OS" = Darwin ] && { [ -z "$U" ] || [ "$U" = root ]; }; then
		U="$(echo "show State:/Users/ConsoleUser" | scutil 2>/dev/null \
			| awk '/Name :/ && ! /loginwindow/ { print $3 }' || true)"
	fi
	if [ -z "$U" ] || { [ "$U" = root ] && [ -z "$USER_OVERRIDE" ]; }; then
		# Root consoles (Alpine, FreeBSD, a rescue shell) have no SUDO_USER to go on.
		_du_users="$(candidate_users | sed '/^$/d')"
		if [ -n "$_du_users" ]; then
			_du_users="$_du_users
root"
			# "name<TAB>home" pairs: the menu aligns the homes as dim notes.
			_du_menu=""
			for _du_u in $_du_users; do
				_du_menu="$_du_menu$_du_u	$(home_of "$_du_u")
"
			done
			_du_menu="$(printf '%s' "$_du_menu")"
			menu_select "Which user should Machman set up SSH for?" "$_du_menu" 1
			U="${R_ITEM%%	*}"
		elif [ "$INTERACTIVE" -eq 1 ]; then
			U=root
			say "This guest has no regular user account — setting SSH up for root."
		fi
	fi
	[ -n "$U" ] || die 3 "cannot tell which user to set up." \
		"Name one:  sh install.sh --user <name>"
	valid_username "$U" || die 3 "\"$U\" is not a usable user name." \
		"Letters, digits, dot, dash and underscore only."
	GROUP="$(id -gn "$U" 2>/dev/null || true)"
	[ -n "$GROUP" ] || die 3 "there is no user \"$U\" in this guest." \
		"Run without --user to pick from the accounts that exist."
	HOME_DIR="$(home_of "$U")"
	[ -n "$HOME_DIR" ] || die 3 "$U has no home directory in this guest." \
		"SSH needs one for ~/.ssh — create it, or pick another user."
	verbose detect "user=$U home=$HOME_DIR group=$GROUP"
	return 0
}

sshd_active() {
	case "$INIT" in
	systemd) systemctl is-active "$SSHD_UNIT" >/dev/null 2>&1 ;;
	launchd) launchctl print system/com.openssh.sshd >/dev/null 2>&1 ;;
	openbsd-rc) rcctl check sshd >/dev/null 2>&1 ;;
	freebsd-rc) service sshd status >/dev/null 2>&1 ;;
	openrc) rc-service sshd status >/dev/null 2>&1 ;;
	runit) sv status sshd >/dev/null 2>&1 ;;
	*)
		if have pgrep; then
			pgrep -x sshd >/dev/null 2>&1
		else
			ps ax 2>/dev/null | grep -q '[s]shd'
		fi
		;;
	esac
}

detect_sshd() {
	if have sshd || [ -x /usr/sbin/sshd ] || [ -x /usr/libexec/sshd-keygen-wrapper ]; then
		SSHD=installed
	fi
	if sshd_active; then
		SSHD=running
	fi
	verbose detect "sshd=$SSHD"
	return 0
}

# How this payload reached the guest. sshfs means the BSD bootstrap: the user mounted the
# share over SSH by hand, which is itself proof that sshfs works here.
detect_transport() {
	_dt_dev="$(df -P "$PAYLOAD_DIR" 2>/dev/null | awk 'NR == 2 { print $1 }' || true)"
	case "$_dt_dev" in
	*@*:*) TRANSPORT=sshfs ;;
	*)
		if [ -n "$_dt_dev" ] && mount 2>/dev/null | grep -q "^$_dt_dev .*virtiofs"; then
			TRANSPORT=virtiofs
		fi
		;;
	esac
	verbose detect "transport=$TRANSPORT (device ${_dt_dev:-?})"
	return 0
}

fuse_loaded() {
	case "$OS_FAMILY" in
	freebsd) kldstat 2>/dev/null | grep -q fusefs ;;
	*) return 0 ;;
	esac
}

fuse_persisted() {
	case "$OS_FAMILY" in
	freebsd) sysrc -n kld_list 2>/dev/null | grep -q fusefs ;;
	*) return 0 ;;
	esac
}

user_mounts_allowed() {
	case "$OS_FAMILY" in
	freebsd) [ "$(sysctl -n vfs.usermount 2>/dev/null || echo 0)" = "1" ] ;;
	# OpenBSD removed kern.usermount in 5.7: mounting is root-only, full stop.
	openbsd) return 1 ;;
	*) return 0 ;;
	esac
}

detect_sshfs() {
	if have sshfs; then
		SSHFS=1
		SSHFS_VERSION="$(sshfs --version 2>&1 \
			| sed -n 's/.*[Ss][Ss][Hh][Ff][Ss] version //p' | head -n 1 || true)"
	fi
	if fuse_persisted; then FUSE_PERSISTED=1; fi
	if [ "$SSHFS" -eq 1 ] && fuse_loaded && user_mounts_allowed; then
		SSHFS_MOUNT_OK=1
	fi
	verbose detect "sshfs=$SSHFS version=${SSHFS_VERSION:-?}"
	verbose detect "sshfs mountable=$SSHFS_MOUNT_OK fuse-persisted=$FUSE_PERSISTED"
	return 0
}

find_addresses() {
	case "$OS" in
	Darwin|FreeBSD|OpenBSD|NetBSD)
		GATEWAY="$(route -n get default 2>/dev/null \
			| awk '/gateway:/ { print $2; exit }' || true)"
		_fa_if="$(route -n get default 2>/dev/null \
			| awk '/interface:/ { print $2; exit }' || true)"
		if [ "$OS" = Darwin ] && [ -n "$_fa_if" ]; then
			IP="$(ipconfig getifaddr "$_fa_if" 2>/dev/null || true)"
		elif [ -n "$_fa_if" ]; then
			IP="$(ifconfig "$_fa_if" 2>/dev/null | awk '/inet /{ print $2; exit }' || true)"
		fi
		;;
	Linux)
		GATEWAY="$(ip route show default 2>/dev/null \
			| awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }' \
			|| true)"
		if [ -n "$GATEWAY" ]; then
			IP="$(ip route get "$GATEWAY" 2>/dev/null \
				| awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' \
				|| true)"
		fi
		;;
	esac
	verbose detect "ip=${IP:-?} gateway=${GATEWAY:-?}"
	return 0
}

# --------------------------------------------------------------------------- consoles ----

# The guest device name for the index-th virtio console — mirrors the app's
# SerialPortKind.guestDevice table.
console_device() {
	case "$OS_FAMILY" in
	darwin) [ "$1" -eq 0 ] && echo "cu.virtio" || echo "cu.virtio$1" ;;
	freebsd) echo "ttyV$1.0" ;;
	*) echo "hvc$1" ;;
	esac
}

# Is something serving a login on the device right now? Process-table check — fedora/leap
# containers taught us pgrep/fuser cannot be assumed, but ps + grep can.
getty_active_on() {
	ps ax 2>/dev/null | grep -v grep | grep getty | grep -q "[^a-zA-Z0-9]$1\$"
}

# Is a login configured to come back at the next boot? Per-init config check; "auto"
# covers systemd's getty-generator, which spawns serial-getty@hvc0 on its own when the
# device exists.
getty_persistent_on() {
	case "$INIT" in
	systemd)
		if systemctl is-enabled "serial-getty@$1.service" >/dev/null 2>&1; then
			return 0
		fi
		[ "$1" = "hvc0" ] && [ -e /dev/hvc0 ]
		;;
	launchd)
		ls /Library/LaunchDaemons/com.machman.console-getty.*.plist >/dev/null 2>&1 \
			&& grep -l "<string>$1</string>" \
				/Library/LaunchDaemons/com.machman.console-getty.*.plist >/dev/null 2>&1
		;;
	inittab|sysv|openrc)
		grep -q "^[^#]*[: ]$1[ :]" /etc/inittab 2>/dev/null \
			|| grep -q "^[^#]*getty.*[^a-zA-Z0-9]$1\$" /etc/inittab 2>/dev/null
		;;
	runit)
		[ -e "/var/service/agetty-$1" ] || [ -e "/etc/runit/runsvdir/default/agetty-$1" ]
		;;
	freebsd-rc)
		grep -q "^$1[[:space:]]" /etc/ttys 2>/dev/null \
			&& ! grep -q "^$1[[:space:]].*[[:space:]]off" /etc/ttys 2>/dev/null
		;;
	*)
		return 1
		;;
	esac
}

# ------------------------------------------------------------------------- bootloader ----

detect_cmdline_consoles() {
	CMDLINE_CONSOLES=""
	[ -r /proc/cmdline ] || return 0
	for _dcc_word in $(cat /proc/cmdline); do
		case "$_dcc_word" in
		console=*)
			_dcc_dev="${_dcc_word#console=}"
			_dcc_dev="${_dcc_dev%%,*}"
			CMDLINE_CONSOLES="$CMDLINE_CONSOLES $_dcc_dev"
			;;
		esac
	done
	CMDLINE_CONSOLES="${CMDLINE_CONSOLES# }"
	verbose detect "cmdline consoles=${CMDLINE_CONSOLES:-none}"
	return 0
}

# Which tool owns the kernel command line here. Order matters: grubby handles BLS distros
# (fedora/rhel) that ALSO have grub2-mkconfig; the plain grub tools want an
# /etc/default/grub edit first. aarch64 has no extlinux — this list is complete for the
# guests Machman can run.
detect_bootloader() {
	BOOTLOADER=none
	linux_guest || return 0
	if have grubby; then BOOTLOADER=grubby
	elif have update-grub && [ -f /etc/default/grub ]; then BOOTLOADER=update-grub
	elif have grub-mkconfig && [ -f /etc/default/grub ]; then BOOTLOADER=grub-mkconfig
	elif have grub2-mkconfig && [ -f /etc/default/grub ]; then BOOTLOADER=grub2-mkconfig
	elif [ -d /boot/loader/entries ]; then BOOTLOADER=systemd-boot
	elif [ -f /etc/kernel/cmdline ]; then BOOTLOADER=kernel-cmdline
	fi
	verbose detect "bootloader=$BOOTLOADER"
	return 0
}

# ------------------------------------------------------------------- virtiofs ability ----

detect_virtiofs() {
	VIRTIOFS_OK=0
	case "$OS_FAMILY" in
	darwin)
		VIRTIOFS_OK=1 ;;   # the OS automounts the share itself
	freebsd|openbsd|netbsd)
		VIRTIOFS_OK=0 ;;   # no driver in base
	*)
		# Proven when the payload arrived that way; else ask the kernel. mount(2)
		# autoloads fs modules by name, so a module merely not-yet-loaded still counts.
		if [ "$TRANSPORT" = virtiofs ] \
			|| grep -qw virtiofs /proc/filesystems 2>/dev/null \
			|| modprobe -qn virtiofs 2>/dev/null; then
			VIRTIOFS_OK=1
		fi
		;;
	esac
	verbose detect "virtiofs=$VIRTIOFS_OK"
	return 0
}
