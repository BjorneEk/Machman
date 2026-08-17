# === machman-setup: 15-args ===
# Tri-state options: empty means "ask" (or take the state file's answer), 1/0 come from
# the paired --x/--no-x flags. F_WANT_<feature> drives the top-level selection.

F_WANT_console=""
F_WANT_kernelconsole=""
F_WANT_ssh=""
F_WANT_reverse=""
F_WANT_sshfs=""
F_WANT_vfsauto=""
F_WANT_sshfsauto=""
WANT_MOUNT_SETUP=""
DO_INSTALL=""
CONSOLES_OVERRIDE=""       # --consoles "hvc0 hvc1"
KERNEL_CONSOLE_DEVICE=""   # --kernel-console=<dev>
MOUNTPOINT=""
UNINSTALL=0
NO_SERVICE=0
USER_OVERRIDE=""
PM_OVERRIDE=""

while [ $# -gt 0 ]; do
	case "$1" in
	--console) F_WANT_console=1 ;;
	--no-console) F_WANT_console=0 ;;
	--consoles)
		shift
		[ $# -gt 0 ] || { usage >&2; exit 64; }
		F_WANT_console=1
		CONSOLES_OVERRIDE="$1"
		;;
	--kernel-console) F_WANT_kernelconsole=1 ;;
	--kernel-console=*)
		F_WANT_kernelconsole=1
		KERNEL_CONSOLE_DEVICE="${1#--kernel-console=}"
		;;
	--no-kernel-console) F_WANT_kernelconsole=0 ;;
	--ssh) F_WANT_ssh=1 ;;
	--no-ssh) F_WANT_ssh=0 ;;
	--two-way) F_WANT_reverse=1 ;;
	--one-way) F_WANT_reverse=0 ;;
	--sshfs)
		F_WANT_sshfs=1
		[ -z "$F_WANT_reverse" ] && F_WANT_reverse=1
		;;
	--no-sshfs) F_WANT_sshfs=0 ;;
	--automount-virtiofs) F_WANT_vfsauto=1 ;;
	--no-automount-virtiofs) F_WANT_vfsauto=0 ;;
	--automount-sshfs) F_WANT_sshfsauto=1 ;;
	--no-automount-sshfs) F_WANT_sshfsauto=0 ;;
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
	--version) echo "machman guest setup v$SCRIPT_VERSION ($MARKER)"; exit 0 ;;
	*)
		echo "unknown option: $1" >&2
		usage >&2
		exit 64
		;;
	esac
	shift
done
# Where sshfs host folders would mount. Machman owns the path (GuestPaths) and hands it
# over in machman.env, so the guide, the app and this script cannot disagree about it.
[ -n "$MOUNTPOINT" ] || MOUNTPOINT="$MOUNT_ROOT"

ui_detect

PREFLIGHT_DONE=0
on_exit() {
	_x_code=$?
	# A failure after preflight means the guest was touched: say so where Machman can see
	# it — unless the run already wrote its own report (a partial exit is an explained
	# outcome, not a crash to overwrite it with).
	if [ "$_x_code" -ne 0 ] && [ "$PREFLIGHT_DONE" -eq 1 ] && [ "$UNINSTALL" -eq 0 ] \
		&& [ "$REPORT_DONE" -eq 0 ]; then
		write_report failed
	fi
	machman_exit_trap "$_x_code"
}
trap on_exit EXIT
