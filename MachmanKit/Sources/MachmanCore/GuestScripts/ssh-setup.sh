#!/bin/sh
# Machman SSH setup — enables this guest's SSH server, installs the Mac's public key for
# one user, and optionally prepares guest → host SSH and sshfs. Machman rewrites this
# payload in the share at every VM start; run this copy, not one you moved elsewhere.
#
#   sh install.sh                interactive — asks only what it cannot work out
#   sh install.sh -n             print the plan and change nothing
#   sh install.sh -y --two-way   unattended
#   sh install.sh --uninstall    remove everything it installed
#
# It is allowed not to succeed. It is not allowed to fail without saying why: every
# decision is resolved and shown before anything is touched, every action is a named step,
# and whatever happens is reported back to Machman.
set -eu

SCRIPT_VERSION=2

# ------------------------------------------------------------------- payload bootstrap ----

PAYLOAD_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
for _needed in machman-lib.sh machman.env; do
	if [ ! -r "$PAYLOAD_DIR/$_needed" ]; then
		echo "$_needed is missing next to this script — run the copy Machman put in the" >&2
		echo "share, not install.sh on its own." >&2
		exit 3
	fi
done
. "$PAYLOAD_DIR/machman-lib.sh"
# VM_NAME, MARKER, REPORT_DIR_NAME, MOUNT_ROOT, HOST_USER, HOST_NAME, HOST_LOCAL
. "$PAYLOAD_DIR/machman.env"
REPORT_DIR="$PAYLOAD_DIR/../$REPORT_DIR_NAME"
# Resolved when it exists, so everything the user sees is a real path.
if _resolved="$(CDPATH= cd -- "$REPORT_DIR" 2>/dev/null && pwd)"; then
	REPORT_DIR="$_resolved"
fi

# ------------------------------------------------------------------------------ usage ----

usage() {
	cat <<USAGE
Machman SSH setup for "$VM_NAME" (script v$SCRIPT_VERSION)

usage: sh install.sh [options]
       sh install.sh --uninstall [--user <name>]

Who
  --user <name>        set SSH up for this user (default: the invoking user)
What
  --two-way            also configure guest -> host SSH   (default: ask)
  --one-way            skip guest -> host SSH
  --sshfs              install sshfs in the guest (implies --two-way)
  --no-sshfs           leave sshfs alone
  --mount-setup        let ANY user of the guest mount filesystems
                       (vfs.usermount=1; root can mount without it)
  --no-mount-setup
  --mountpoint <path>  where host folders get mounted (default $MOUNT_ROOT)
  --install            install missing packages with this guest's package manager
  --no-install
  --pm <name>          force the package manager (apt, dnf, yum, zypper, pacman, apk,
                       xbps, emerge, pkg, pkg_add)
  --no-service         install the key only; do not touch services
How
  -y, --yes            never ask; take the defaults shown by --dry-run
  -n, --dry-run        print the plan and exit; change nothing
  -v, --verbose        narrate every decision and command
  -q, --quiet          only the summary and errors
  -h, --help           this text
      --version        print the script version
      --uninstall      remove everything this script installed

Exit codes: 0 done, 3 refused before touching anything, 4 partial (see the report),
1 a step failed, 64 bad usage.
USAGE
}

# ---------------------------------------------------------------------------- options ----

TWO_WAY=""
DO_INSTALL=""
WANT_SSHFS=""
WANT_MOUNT_SETUP=""
MOUNTPOINT=""
UNINSTALL=0
NO_SERVICE=0
USER_OVERRIDE=""
PM_OVERRIDE=""

while [ $# -gt 0 ]; do
	case "$1" in
	--two-way) TWO_WAY=1 ;;
	--one-way) TWO_WAY=0 ;;
	--sshfs) WANT_SSHFS=1; [ -z "$TWO_WAY" ] && TWO_WAY=1 ;;
	--no-sshfs) WANT_SSHFS=0 ;;
	--mount-setup) WANT_MOUNT_SETUP=1 ;;
	--no-mount-setup) WANT_MOUNT_SETUP=0 ;;
	--mountpoint)
		shift
		[ $# -gt 0 ] || { usage >&2; exit 64; }
		MOUNTPOINT="$1"
		;;
	--install) DO_INSTALL=1 ;;
	--no-install) DO_INSTALL=0 ;;
	--pm)
		shift
		[ $# -gt 0 ] || { usage >&2; exit 64; }
		PM_OVERRIDE="$1"
		;;
	--no-service) NO_SERVICE=1 ;;
	--user)
		shift
		[ $# -gt 0 ] || { usage >&2; exit 64; }
		USER_OVERRIDE="$1"
		;;
	--uninstall) UNINSTALL=1 ;;
	-y|--yes) ASSUME_YES=1 ;;
	-n|--dry-run) DRY_RUN=1 ;;
	-v|--verbose) VERBOSE=1 ;;
	-q|--quiet) QUIET=1 ;;
	-h|--help) usage; exit 0 ;;
	--version) echo "machman ssh-setup v$SCRIPT_VERSION ($MARKER)"; exit 0 ;;
	*)
		echo "unknown option: $1" >&2
		usage >&2
		exit 64
		;;
	esac
	shift
done
# Where host folders would mount. Machman owns the path (GuestPaths) and hands it over in
# machman.env, so the guide, the app and this script cannot disagree about it.
[ -n "$MOUNTPOINT" ] || MOUNTPOINT="$MOUNT_ROOT"

ui_detect

PREFLIGHT_DONE=0
on_exit() {
	_x_code=$?
	# A failure after preflight means the guest was touched: say so where Machman can see
	# it, then let the library explain it on screen.
	if [ "$_x_code" -ne 0 ] && [ "$PREFLIGHT_DONE" -eq 1 ] && [ "$UNINSTALL" -eq 0 ]; then
		write_report failed
	fi
	machman_exit_trap "$_x_code"
}
trap on_exit EXIT

# -------------------------------------------------------------------------- detection ----

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
			"Machman's script covers Linux, FreeBSD, OpenBSD and macOS guests."
		;;
	esac
	verbose detect "os=$OS_ID family=$OS_FAMILY version=${OS_VERSION:-?}"
	return 0
}

detect_init() {
	# sd_booted(3), not `command -v systemctl`: Devuan ships apt without systemd.
	if [ -d /run/systemd/system ]; then INIT=systemd
	elif [ "$OS" = Darwin ]; then INIT=launchd
	elif have rcctl; then INIT=openbsd-rc
	elif have sysrc; then INIT=freebsd-rc
	elif have rc-update && [ -d /etc/runlevels ]; then INIT=openrc
	elif have sv && [ -d /var/service ]; then INIT=runit
	elif have service || [ -d /etc/init.d ]; then INIT=sysv
	else INIT=unknown
	fi
	[ "$OS_FAMILY" = debian ] && SSHD_UNIT=ssh
	verbose detect "init=$INIT unit=$SSHD_UNIT"
	return 0
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
		ask_choice "Which package manager should Machman use?" "$_dp_found" 1
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
			ask_choice "Which user should Machman set up SSH for?" "$_du_users" 1
			U="$R_ITEM"
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

# -------------------------------------------------------------------------- decisions ----

SSHD_PLAN=""        # what we will do about the server
SSHFS_PLAN=""       # …about sshfs
MOUNT_PLAN=""       # …about the fuse module and the mount point
USER_MOUNT_PLAN=""  # …about the vfs.usermount permission

decide_sshd() {
	if [ "$NO_SERVICE" -eq 1 ]; then
		SSHD_PLAN="left alone (--no-service)"
		return 0
	fi
	if [ "$SSHD" = missing ]; then
		_ds_pkgs="$(pkg_for_sshd)"
		if [ "$OS_FAMILY" = nixos ]; then
			SSHD_PLAN="declarative — configuration.nix + rebuild"
			if [ -z "$DO_INSTALL" ]; then
				ask_yes_no "Add services.openssh to /etc/nixos/configuration.nix and rebuild?" n
				DO_INSTALL="$R_YES"
			fi
			[ "$DO_INSTALL" = 1 ] || SSHD_PLAN="NOT installed — NixOS needs a config change"
			return 0
		fi
		if [ -z "$_ds_pkgs" ] || [ -z "$PM" ]; then
			SSHD_PLAN="NOT installed — no package manager to install it with"
			return 0
		fi
		if [ -z "$DO_INSTALL" ]; then
			ask_yes_no "The SSH server is not installed. Install it ($(pm_command) $_ds_pkgs)?" y
			DO_INSTALL="$R_YES"
		fi
		if [ "$DO_INSTALL" = 1 ]; then
			SSHD_PLAN="install ($_ds_pkgs), then enable"
		else
			SSHD_PLAN="NOT installed — install it and re-run"
		fi
		return 0
	fi
	if [ "$SSHD" = running ]; then
		SSHD_PLAN="already running — make sure it stays enabled"
	else
		SSHD_PLAN="installed, not running — enable and start"
	fi
	return 0
}

decide_two_way() {
	if [ -z "$TWO_WAY" ]; then
		ask_yes_no "Also set up guest -> host SSH back to the Mac?" n
		TWO_WAY="$R_YES"
	fi
	return 0
}

decide_sshfs() {
	if [ "$TWO_WAY" != "1" ]; then
		# sshfs mounts host folders over the guest -> host link; without it there is
		# nothing to mount with.
		[ "$WANT_SSHFS" = "1" ] && SSHFS_PLAN="skipped — needs guest -> host SSH"
		WANT_SSHFS=0
		return 0
	fi
	if [ "$SSHFS" -eq 1 ]; then
		# Already there: the only question is whether Machman should know about it.
		if [ -z "$WANT_SSHFS" ]; then
			ask_yes_no "sshfs is already installed. Tell Machman this guest can mount host folders?" y
			WANT_SSHFS="$R_YES"
		fi
		if [ "$WANT_SSHFS" = 1 ]; then
			SSHFS_PLAN="already installed${SSHFS_VERSION:+ ($SSHFS_VERSION)} — report the capability"
		else
			SSHFS_PLAN="installed, not reported"
		fi
		return 0
	fi
	_dsf_pkgs="$(pkg_for_sshfs)"
	if [ -z "$_dsf_pkgs" ] || [ -z "$PM" ]; then
		SSHFS_PLAN="not installed — no package for it on this guest"
		WANT_SSHFS=0
		[ "$OS_FAMILY" = darwin ] && SSHFS_PLAN="not installed — needs macFUSE (install it yourself)"
		return 0
	fi
	if [ -z "$WANT_SSHFS" ]; then
		ask_yes_no "Install sshfs so this guest can mount host folders?" n
		WANT_SSHFS="$R_YES"
	fi
	if [ "$WANT_SSHFS" = 1 ]; then
		SSHFS_PLAN="install ($_dsf_pkgs)"
	else
		SSHFS_PLAN="not installed"
	fi
	return 0
}

# Two separate things, deliberately:
#
#   * the fuse module and a mount point — harmless plumbing, done whenever sshfs is set
#     up, because a driver that is not loaded at boot just breaks the next mount;
#   * vfs.usermount — a system-wide permission that lets ANY user of this guest mount
#     filesystems. Root can mount without it, so it is never assumed, never implied by
#     something else, and never turned on silently. Only --mount-setup or an explicit
#     "yes" enables it.
decide_mount_setup() {
	MOUNT_PLAN=""
	USER_MOUNT_PLAN=""
	if [ "$WANT_SSHFS" != "1" ]; then
		WANT_MOUNT_SETUP=0
		return 0
	fi
	MOUNT_PLAN="$MOUNTPOINT"
	[ -d "$MOUNTPOINT" ] && MOUNT_PLAN="$MOUNT_PLAN (exists)"
	if ! fuse_loaded; then
		MOUNT_PLAN="$MOUNT_PLAN, load fusefs"
	fi
	if [ "$OS_FAMILY" = freebsd ] && [ "$FUSE_PERSISTED" -eq 0 ]; then
		MOUNT_PLAN="$MOUNT_PLAN, keep fusefs across reboots"
	fi
	if [ "$OS_FAMILY" = openbsd ]; then
		# OpenBSD removed kern.usermount in 5.7 — there is no knob to offer.
		USER_MOUNT_PLAN="root only (OpenBSD has no user mounts)"
		WANT_MOUNT_SETUP=0
	elif user_mounts_allowed; then
		USER_MOUNT_PLAN="already allowed"
		WANT_MOUNT_SETUP=0
	else
		if [ -z "$WANT_MOUNT_SETUP" ]; then
			ask_yes_no "Let ANY user of this guest mount filesystems (vfs.usermount=1)? Root can mount without it." n
			WANT_MOUNT_SETUP="$R_YES"
		fi
		if [ "$WANT_MOUNT_SETUP" = 1 ]; then
			USER_MOUNT_PLAN="enable vfs.usermount=1"
		else
			USER_MOUNT_PLAN="left off — mount as root"
		fi
	fi
	return 0
}

# -------------------------------------------------------------------------- preflight ----

plan_line() {
	[ "$QUIET" -eq 1 ] && return 0
	printf '  %-14s %s\n' "$1" "$2"
	return 0
}

preflight() {
	# Everything checkable, checked before anything is touched.
	[ -r "$PAYLOAD_DIR/host_key.pub" ] || die 3 \
		"the Mac's public key is missing from the payload." \
		"Restart the VM so Machman regenerates the share, then re-run."
	if [ ! -d "$HOME_DIR" ]; then
		die 3 "$HOME_DIR does not exist." "Log in as $U once to create it, then re-run."
	fi
	if [ "$TWO_WAY" = "1" ] && ! have ssh-keygen; then
		die 3 "ssh-keygen is missing, so guest -> host SSH cannot be prepared." \
			"Install the OpenSSH client, or re-run with --one-way."
	fi

	say ""
	say "${C_BOLD}Machman SSH setup${C_RESET} — VM \"$VM_NAME\", script v$SCRIPT_VERSION"
	say ""
	plan_line "guest" "${OS_ID}${OS_VERSION:+ $OS_VERSION} ($OS_FAMILY), $INIT init${PM_NAME:+, $PM_NAME}"
	plan_line "payload" "$PAYLOAD_DIR (over $TRANSPORT)"
	plan_line "user" "$U -> $HOME_DIR"
	plan_line "ssh server" "$SSHD_PLAN"
	plan_line "host key" "the Mac's key -> $HOME_DIR/.ssh/authorized_keys"
	if [ "$TWO_WAY" = "1" ]; then
		plan_line "guest -> host" "ssh mac -> ${GATEWAY:-?} as $HOST_USER (needs approval in Machman)"
	else
		plan_line "guest -> host" "not configured"
	fi
	[ -n "$SSHFS_PLAN" ] && plan_line "sshfs" "$SSHFS_PLAN"
	[ -n "$MOUNT_PLAN" ] && plan_line "mount point" "$MOUNT_PLAN"
	[ -n "$USER_MOUNT_PLAN" ] && plan_line "user mounts" "$USER_MOUNT_PLAN"
	if [ -d "$REPORT_DIR" ] && [ -w "$REPORT_DIR" ]; then
		plan_line "report" "$REPORT_DIR"
	else
		plan_line "report" "NOT writable — Machman will not learn any of this"
	fi
	say ""
	return 0
}

# ---------------------------------------------------------------------------- actions ----

enable_sshd() {
	case "$INIT" in
	launchd)
		# The systemsetup remote-login toggle is Full-Disk-Access-gated and FAILS in a
		# fresh VM; launchd control is not TCC-gated and persists across boots.
		if ! launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
			run "enabling sshd" launchctl enable system/com.openssh.sshd \
				|| return 1
			run "starting sshd" launchctl bootstrap system \
				/System/Library/LaunchDaemons/ssh.plist || true
		fi
		# macOS mints host keys at the first CONNECTION — create them now instead.
		[ -f /etc/ssh/ssh_host_ed25519_key.pub ] || run "creating host keys" ssh-keygen -A
		;;
	systemd)
		run "enabling sshd" systemctl enable --now "$SSHD_UNIT" || return 1
		;;
	freebsd-rc)
		run "enabling sshd" sysrc sshd_enable=YES || return 1
		run "starting sshd" service sshd start || run "restarting sshd" service sshd restart \
			|| true
		;;
	openbsd-rc)
		run "enabling sshd" rcctl enable sshd || return 1
		run "starting sshd" rcctl start sshd || true
		;;
	openrc)
		run "enabling sshd" rc-update add sshd default || return 1
		run "starting sshd" rc-service sshd start || run "restarting sshd" \
			rc-service sshd restart || true
		;;
	runit)
		if [ ! -e /var/service/sshd ]; then
			run "enabling sshd" ln -s /etc/sv/sshd /var/service/ || return 1
		fi
		run "starting sshd" sv up sshd || true
		;;
	sysv)
		if have update-rc.d; then
			run "enabling sshd" update-rc.d "$SSHD_UNIT" defaults || true
		elif have chkconfig; then
			run "enabling sshd" chkconfig "$SSHD_UNIT" on || true
		fi
		run "starting sshd" service "$SSHD_UNIT" start || return 1
		;;
	*)
		return 1
		;;
	esac
	return 0
}

act_sshd() {
	[ "$NO_SERVICE" -eq 1 ] && return 0
	if [ "$OS_FAMILY" = nixos ]; then
		act_sshd_nixos
		return 0
	fi
	if [ "$SSHD" = missing ]; then
		if [ "$DO_INSTALL" = 1 ]; then
			# shellcheck disable=SC2086
			if pm_install $(pkg_for_sshd); then
				SSHD=installed
			else
				die 1 "could not install the SSH server${R_ERROR:+: $R_ERROR}" \
					"Install it yourself, then re-run this script."
			fi
		else
			step_failed sshd "the SSH server is not installed — nothing to enable" \
				"Install it ($(pm_command) $(pkg_for_sshd)), or re-run with --install."
			return 0
		fi
	fi
	if enable_sshd; then
		ok "sshd is enabled and running"
	else
		step_failed sshd "could not enable the '$SSHD_UNIT' service${R_ERROR:+: $R_ERROR}" \
			"Start it with your init system ($INIT), then re-run."
	fi
	if [ "$OS_FAMILY" = suse ] && have firewall-cmd; then
		# openSUSE's firewall blocks port 22 by default on desktop roles.
		run "opening the firewall for ssh" firewall-cmd --permanent --add-service=ssh || true
		run "reloading the firewall" firewall-cmd --reload || true
	fi
	return 0
}

act_sshd_nixos() {
	if sshd_active; then
		ok "sshd is already enabled (declaratively) — nothing to change"
		return 0
	fi
	if [ "$DO_INSTALL" != 1 ] || [ ! -f /etc/nixos/configuration.nix ] \
		|| grep -q "services.openssh" /etc/nixos/configuration.nix; then
		step_failed sshd "NixOS is declarative — sshd cannot be enabled from a script here" \
			"Add 'services.openssh.enable = true;' to /etc/nixos/configuration.nix, run 'nixos-rebuild switch', then re-run. Your key is installed either way."
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add services.openssh to configuration.nix and rebuild"
		return 0
	fi
	# One marked line inside the final brace, backed up first.
	cp /etc/nixos/configuration.nix /etc/nixos/configuration.nix.machman-backup
	awk -v m="$MARKER" '
		{ lines[NR] = $0 }
		END {
			for (i = NR; i >= 1; i--) {
				if (lines[i] ~ /^}/) {
					lines[i] = "  services.openssh.enable = true; # " m "\n" lines[i]
					break
				}
			}
			for (i = 1; i <= NR; i++) print lines[i]
		}
	' /etc/nixos/configuration.nix.machman-backup > /etc/nixos/configuration.nix
	if run_live "rebuilding NixOS (slow)" nixos-rebuild switch; then
		ok "sshd enabled in configuration.nix and rebuilt"
	else
		step_failed sshd "nixos-rebuild failed — configuration.nix keeps the Machman line" \
			"Fix the error it printed and run 'nixos-rebuild switch' yourself."
	fi
	return 0
}

act_install_key() {
	STEP="installing the Mac's key"
	_aik_key="$(cat "$PAYLOAD_DIR/host_key.pub")"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add the Mac's key to $HOME_DIR/.ssh/authorized_keys"
		return 0
	fi
	mkdir -p "$HOME_DIR/.ssh"
	touch "$HOME_DIR/.ssh/authorized_keys"
	if ! grep -qF "$_aik_key" "$HOME_DIR/.ssh/authorized_keys"; then
		printf '%s\n' "$_aik_key" >> "$HOME_DIR/.ssh/authorized_keys"
	fi
	chown "$U:$GROUP" "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/authorized_keys"
	chmod 700 "$HOME_DIR/.ssh"
	chmod 600 "$HOME_DIR/.ssh/authorized_keys"
	# SELinux (rhel-family, Leap 16): a root-written authorized_keys can land with the
	# wrong context and be silently refused — exactly what ssh-copy-id fixes up.
	if have restorecon; then
		restorecon -R "$HOME_DIR/.ssh" 2>/dev/null || true
	fi
	ok "the Mac's key is installed for $U"
	return 0
}

strip_block() {
	[ -f "$1" ] || return 0
	_sb_tmp="$1.machman-tmp"
	awk -v m="$MARKER" '
		$0 == "# BEGIN " m { skip = 1; next }
		$0 == "# END " m { skip = 0; next }
		!skip { print }
	' "$1" > "$_sb_tmp"
	mv "$_sb_tmp" "$1"
	return 0
}

act_two_way() {
	[ "$TWO_WAY" = "1" ] || return 0
	STEP="preparing guest -> host SSH"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would create $HOME_DIR/.ssh/machman_host and a 'mac' host entry"
		return 0
	fi
	_atw_dir="$HOME_DIR/.ssh"
	_atw_key="$_atw_dir/machman_host"
	mkdir -p "$_atw_dir"
	if [ ! -f "$_atw_key" ]; then
		run "creating the guest's key" ssh-keygen -q -t ed25519 -N "" \
			-C "$MARKER-reverse" -f "$_atw_key" \
			|| die 1 "ssh-keygen could not create the guest's key${R_ERROR:+: $R_ERROR}" \
				"Check $_atw_dir is writable, then re-run."
	fi
	REVERSE_PUBKEY="$(cat "$_atw_key.pub")"
	_atw_target="$GATEWAY"
	if [ "$OS" = Darwin ] && [ -n "$HOST_LOCAL" ]; then
		# Bonjour name survives NAT-subnet renumbering; macOS guests resolve it.
		_atw_target="$HOST_LOCAL"
	fi
	if [ -z "$_atw_target" ]; then
		step_failed two-way "no route to the Mac was found — 'ssh mac' was not configured" \
			"The key is reported anyway; re-run once the guest has a default route."
		chown "$U:$GROUP" "$_atw_key" "$_atw_key.pub"
		chmod 600 "$_atw_key"
		return 0
	fi
	# Pin the Mac's host key so the first guest -> host connect has no TOFU prompt.
	_atw_known=""
	if [ -r "$PAYLOAD_DIR/host_machine_key.pub" ]; then
		_atw_hk="$(awk '{ print $1" "$2 }' "$PAYLOAD_DIR/host_machine_key.pub")"
		_atw_known="$_atw_dir/machman_known_hosts"
		{
			[ -n "$GATEWAY" ] && printf '%s %s\n' "$GATEWAY" "$_atw_hk"
			[ -n "$HOST_LOCAL" ] && printf '%s %s\n' "$HOST_LOCAL" "$_atw_hk"
			:
		} > "$_atw_known"
		chown "$U:$GROUP" "$_atw_known"
		chmod 600 "$_atw_known"
	fi
	_atw_config="$_atw_dir/config"
	touch "$_atw_config"
	strip_block "$_atw_config"
	{
		printf '# BEGIN %s\n' "$MARKER"
		printf 'Host mac\n'
		printf '\tHostName %s\n' "$_atw_target"
		printf '\tUser %s\n' "$HOST_USER"
		printf '\tIdentityFile %s\n' "$_atw_key"
		printf '\tIdentitiesOnly yes\n'
		[ -n "$_atw_known" ] && printf '\tUserKnownHostsFile %s\n' "$_atw_known"
		printf '# END %s\n' "$MARKER"
	} >> "$_atw_config"
	chown "$U:$GROUP" "$_atw_config" "$_atw_key" "$_atw_key.pub"
	chmod 600 "$_atw_config" "$_atw_key"
	ok "guest -> host ready: 'ssh mac' reaches ${_atw_target}${HOST_NAME:+ ($HOST_NAME)} as $HOST_USER"
	note "It works once you approve this VM in Machman and Remote Login is on."
	return 0
}

act_sshfs() {
	[ "$WANT_SSHFS" = "1" ] || return 0
	if [ "$SSHFS" -eq 0 ]; then
		# shellcheck disable=SC2086
		if pm_install $(pkg_for_sshfs); then
			SSHFS=1
			SSHFS_VERSION="$(sshfs --version 2>&1 \
				| sed -n 's/.*[Ss][Ss][Hh][Ff][Ss] version //p' | head -n 1 || true)"
			ok "sshfs installed${SSHFS_VERSION:+ ($SSHFS_VERSION)}"
		else
			step_failed sshfs "could not install sshfs${R_ERROR:+: $R_ERROR}" \
				"Install it yourself and re-run; everything else is unaffected."
			return 0
		fi
	fi
	act_fuse_ready
	act_user_mounts
	if [ "$SSHFS" -eq 1 ] && fuse_loaded && user_mounts_allowed; then
		SSHFS_MOUNT_OK=1
	fi
	return 0
}

# The plumbing: a loaded (and still-loaded-next-boot) fuse driver, and somewhere to mount.
act_fuse_ready() {
	if [ "$OS_FAMILY" = freebsd ]; then
		if ! fuse_loaded; then
			run "loading the fuse module" kldload fusefs \
				|| step_failed sshfs "could not load the fusefs module" \
					"Load it yourself: kldload fusefs"
		fi
		if [ "$FUSE_PERSISTED" -eq 0 ]; then
			# The BSD bootstrap loads fusefs by hand for one boot; make it stick, or the
			# next boot quietly loses the ability to mount anything.
			run "keeping fusefs across reboots" sysrc "kld_list+=fusefs" \
				|| step_failed sshfs "could not persist the fusefs module" \
					"Add it yourself: sysrc kld_list+=fusefs"
		fi
	fi
	if [ ! -d "$MOUNTPOINT" ]; then
		run "creating $MOUNTPOINT" mkdir -p "$MOUNTPOINT" \
			|| step_failed sshfs "could not create $MOUNTPOINT" \
				"Create it yourself, or pass --mountpoint <path>."
	fi
	if [ -d "$MOUNTPOINT" ] || [ "$DRY_RUN" -eq 1 ]; then
		run "giving $U the mount point" chown "$U:$GROUP" "$MOUNTPOINT" || true
	fi
	ok "$MOUNTPOINT is ready for host folders"
	return 0
}

# The permission. Only ever reached when the user said yes to exactly this.
act_user_mounts() {
	[ "$WANT_MOUNT_SETUP" = "1" ] || return 0
	[ "$OS_FAMILY" = freebsd ] || return 0
	if ! run "allowing user mounts" sysctl vfs.usermount=1; then
		step_failed mount-setup "could not set vfs.usermount" \
			"Set it yourself: sysctl vfs.usermount=1"
		return 0
	fi
	if [ "$DRY_RUN" -eq 0 ] && ! grep -q '^vfs.usermount' /etc/sysctl.conf 2>/dev/null; then
		echo 'vfs.usermount=1' >> /etc/sysctl.conf
	fi
	ok "user mounts allowed (vfs.usermount=1)"
	return 0
}

collect_host_key() {
	if [ "$OS_FAMILY" != nixos ] && [ ! -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
		ssh-keygen -A 2>/dev/null || true
	fi
	if [ -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
		GUEST_HOST_KEY="$(cat /etc/ssh/ssh_host_ed25519_key.pub)"
	fi
	return 0
}

# ----------------------------------------------------------------------------- report ----

# Always written when the drop-box is writable — including on failure, so Machman can say
# what went wrong instead of just "no report yet".
write_report() {
	_wr_mode="${1:-}"
	if [ ! -d "$REPORT_DIR" ] || [ ! -w "$REPORT_DIR" ]; then
		return 0
	fi
	_wr_status=ok
	case "$_wr_mode" in
	failed) _wr_status=failed ;;
	uninstalled) _wr_status=ok ;;
	*) [ -n "$FAILED_STEPS" ] && _wr_status=partial ;;
	esac
	{
		printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
		printf 'MARKER=%s\n' "$MARKER"
		printf 'STATUS=%s\n' "$_wr_status"
		[ -n "$FAILED_STEPS" ] && printf 'FAILED_STEPS=%s\n' "$FAILED_STEPS"
		if [ "$_wr_status" = failed ]; then
			printf 'NOTE=%s\n' "${R_LAST_FAILURE:-stopped during: ${STEP:-startup}}"
		elif [ -n "$R_LAST_FAILURE" ]; then
			printf 'NOTE=%s\n' "$R_LAST_FAILURE"
		fi
		printf 'TRANSPORT=%s\n' "$TRANSPORT"
		printf 'OS_ID=%s\n' "$OS_ID"
		printf 'OS_FAMILY=%s\n' "$OS_FAMILY"
		[ -n "$OS_VERSION" ] && printf 'OS_VERSION=%s\n' "$OS_VERSION"
		printf 'INIT=%s\n' "$INIT"
		printf 'SSHD=%s\n' "$SSHD"
		printf 'USER=%s\n' "$U"
		printf 'HOME=%s\n' "$HOME_DIR"
		printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null || true)"
		printf 'IP=%s\n' "$IP"
		printf 'GATEWAY=%s\n' "$GATEWAY"
		printf 'TWO_WAY=%s\n' "${TWO_WAY:-0}"
		printf 'SSHFS=%s\n' "$SSHFS"
		[ -n "$SSHFS_VERSION" ] && printf 'SSHFS_VERSION=%s\n' "$SSHFS_VERSION"
		printf 'SSHFS_MOUNT_OK=%s\n' "$SSHFS_MOUNT_OK"
		[ "$SSHFS" -eq 1 ] && printf 'SSHFS_MOUNTROOT=%s\n' "$MOUNTPOINT"
		[ -n "$GUEST_HOST_KEY" ] && printf 'HOST_KEY=%s\n' "$GUEST_HOST_KEY"
		[ -n "$REVERSE_PUBKEY" ] && printf 'REVERSE_PUBKEY=%s\n' "$REVERSE_PUBKEY"
		[ "$_wr_mode" = uninstalled ] && printf 'UNINSTALLED=1\n'
		:
	} > "$REPORT_DIR/report.env.tmp"
	mv "$REPORT_DIR/report.env.tmp" "$REPORT_DIR/report.env"
	verbose report "wrote $REPORT_DIR/report.env (status=$_wr_status)"
	return 0
}

# -------------------------------------------------------------------------- uninstall ----

do_uninstall() {
	STEP="removing Machman's SSH artifacts"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would remove every line and file carrying $MARKER from $HOME_DIR/.ssh"
		exit 0
	fi
	_du_ak="$HOME_DIR/.ssh/authorized_keys"
	if [ -f "$_du_ak" ]; then
		_du_tmp="$_du_ak.machman-tmp"
		grep -vF "$MARKER" "$_du_ak" > "$_du_tmp" || true
		mv "$_du_tmp" "$_du_ak"
		chown "$U:$GROUP" "$_du_ak"
		chmod 600 "$_du_ak"
	fi
	[ -f "$HOME_DIR/.ssh/config" ] && strip_block "$HOME_DIR/.ssh/config"
	rm -f "$HOME_DIR/.ssh/machman_host" "$HOME_DIR/.ssh/machman_host.pub" \
		"$HOME_DIR/.ssh/machman_known_hosts"
	if [ "$OS_FAMILY" = nixos ] && [ -f /etc/nixos/configuration.nix ] \
		&& grep -q "# $MARKER" /etc/nixos/configuration.nix; then
		_du_tmp="/etc/nixos/configuration.nix.machman-tmp"
		grep -v "# $MARKER" /etc/nixos/configuration.nix > "$_du_tmp"
		mv "$_du_tmp" /etc/nixos/configuration.nix
		note "removed the Machman line from configuration.nix — run 'nixos-rebuild switch'."
	fi
	find_addresses
	write_report uninstalled
	ok "Machman's SSH artifacts are gone from $HOME_DIR"
	note "The SSH server itself was left enabled; disable it yourself if you no longer want it."
	exit 0
}

# ------------------------------------------------------------------------------- main ----

if [ "$(id -u)" -ne 0 ]; then
	if [ "$DRY_RUN" -eq 1 ]; then
		warn "not running as root — the plan below is what a real run would do, and some"
		warn "checks (service state) may read as unknown."
	else
		die 3 "this script has to run as root." \
			"Use:  sudo sh install.sh  (or doas, or a root shell)"
	fi
fi

detect_os
detect_init
detect_user
detect_sshd
detect_transport
detect_sshfs
find_addresses

[ "$UNINSTALL" -eq 1 ] && do_uninstall

detect_pm
decide_sshd
decide_two_way
decide_sshfs
decide_mount_setup
preflight

if [ "$DRY_RUN" -eq 1 ]; then
	say "Dry run — nothing was changed."
	exit 0
fi

ask_yes_no "Proceed?" y
[ "$R_YES" = 1 ] || die 3 "cancelled — nothing was changed."
PREFLIGHT_DONE=1
say ""

act_sshd
act_install_key
act_two_way
act_sshfs
collect_host_key
find_addresses
write_report

say ""
if [ -n "$FAILED_STEPS" ]; then
	warn "done, with gaps: $FAILED_STEPS"
	note "Machman's SSH inspector shows what is missing."
	exit 4
fi
ok "done — SSH is set up for $U."
[ -n "$IP" ] && say "From your Mac:    ssh $U@$IP"
say "Machman shows this VM's address in the Network device's inspector."
