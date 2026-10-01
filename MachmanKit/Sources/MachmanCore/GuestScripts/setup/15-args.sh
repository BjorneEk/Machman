# === machman-setup: 15-args ===
# Tri-state options: empty means "ask" (or take the state file's answer), 1/0 come from
# the paired --x/--no-x flags. want_<feature> drives the top-level selection.

want_console=""
want_kernelconsole=""
want_ssh=""
want_reverse=""
want_sshfs=""
want_vfsauto=""
want_sshfsauto=""
WANT_MOUNT_SETUP=""
DO_INSTALL=""
CONSOLES_OVERRIDE=""       # --consoles "hvc0 hvc1"
KERNEL_CONSOLE_DEVICE=""   # --kernel-console=<dev>
MOUNTPOINT=""
UNINSTALL=0
REPORT_ONLY=0
AT_BOOT=0                  # --at-boot: --report-only, once the share and the network are up
NO_SERVICE=0
USER_OVERRIDE=""
PM_OVERRIDE=""

while [ $# -gt 0 ]; do
	case "$1" in
	--console) want_console=1 ;;
	--no-console) want_console=0 ;;
	--consoles)
		shift
		[ $# -gt 0 ] || { usage >&2; exit 64; }
		want_console=1
		CONSOLES_OVERRIDE="$1"
		;;
	--kernel-console) want_kernelconsole=1 ;;
	--kernel-console=*)
		want_kernelconsole=1
		KERNEL_CONSOLE_DEVICE="${1#--kernel-console=}"
		;;
	--no-kernel-console) want_kernelconsole=0 ;;
	--ssh) want_ssh=1 ;;
	--no-ssh) want_ssh=0 ;;
	--two-way) want_reverse=1 ;;
	--one-way) want_reverse=0 ;;
	--sshfs)
		want_sshfs=1
		[ -z "$want_reverse" ] && want_reverse=1
		;;
	--no-sshfs) want_sshfs=0 ;;
	--automount-virtiofs) want_vfsauto=1 ;;
	--no-automount-virtiofs) want_vfsauto=0 ;;
	--automount-sshfs) want_sshfsauto=1 ;;
	--no-automount-sshfs) want_sshfsauto=0 ;;
	--report-only) REPORT_ONLY=1 ;;
	--at-boot) REPORT_ONLY=1; AT_BOOT=1 ;;
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
# How long --at-boot waits for the share and a default route, and how often it looks.
: "${BOOT_WAIT_SECONDS:=300}"
: "${BOOT_WAIT_POLL:=5}"
# The boot-time copy reports and does nothing else (a root copy that could reconfigure the
# guest is more than a boot hook needs): changes are runs from the share's install.sh.
if [ -n "$BOOT_REPORT_DIR" ] && [ "$REPORT_ONLY" -ne 1 ]; then
	die 3 "this is Machman's boot-time report copy — it only refreshes the report." \
		"Run install.sh from the Machman share to change anything."
fi
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
