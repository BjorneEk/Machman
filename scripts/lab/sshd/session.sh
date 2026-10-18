#!/bin/sh
# The lab sshd's ForceCommand (copied into <run>/sshd/ at start): every session runs in the
# fake home with HOME pointing there and TMPDIR inside the run, under sandbox-exec (session.sb:
# writes only inside the run sandbox and /dev, no ~/.ssh, no unix socket outside
# the run). sftp is served the same way.
# (sshd starts it through the account's login shell, which reads that shell's startup files
# from the real home: reads only, never a write outside the sandbox.)
HOME="${MACHMAN_LAB_HOME:?}"
TMPDIR="${MACHMAN_LAB_RUN:?}/sshd/tmp"
export HOME TMPDIR
mkdir -p "$TMPDIR"
cd "$HOME" || exit 1
sb="$MACHMAN_LAB_RUN/sshd/session.sb"
case "${SSH_ORIGINAL_COMMAND:-}" in
*sftp-server*|internal-sftp*)
	exec /usr/bin/sandbox-exec -f "$sb" /usr/libexec/sftp-server -d "$HOME" ;;
'')
	exec /usr/bin/sandbox-exec -f "$sb" /bin/sh -i ;;
*)
	exec /usr/bin/sandbox-exec -f "$sb" /bin/sh -c "$SSH_ORIGINAL_COMMAND" ;;
esac
