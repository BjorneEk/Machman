# Sourced (POSIX sh): the only sanctioned host-side ssh and scp for the lab. Never the user's
# agent (Secretive, 1Password, Touch ID), keychain, ~/.ssh/config or known_hosts: -F /dev/null,
# IdentityAgent=none, one explicit key, known hosts inside the run sandbox, batch mode.
#
#   lab_ssh <root> <key> <user@host> <port> <command…>
#   lab_scp <root> <key> <port> <source…> <target>      (remote paths as user@host:path)
#
# LAB_KNOWN_HOSTS overrides the known_hosts file (default <root>/ssh/known_hosts), e.g. one
# per guest so two guests that drew the same loopback port never collide.

lab_ssh_known() { # <root>
	if [ -n "${LAB_KNOWN_HOSTS:-}" ]; then
		mkdir -p "$(dirname "$LAB_KNOWN_HOSTS")"
		printf '%s\n' "$LAB_KNOWN_HOSTS"
	else
		mkdir -p "$1/ssh"
		printf '%s\n' "$1/ssh/known_hosts"
	fi
}

lab_ssh() {
	_lr="$1" _lk="$2" _lh="$3" _lp="$4"
	shift 4
	_lkh="$(lab_ssh_known "$_lr")"
	env -u SSH_AUTH_SOCK -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never ssh -F /dev/null \
		-o IdentityAgent=none -o IdentitiesOnly=yes -i "$_lk" -o AddKeysToAgent=no \
		-o UserKnownHostsFile="$_lkh" -o GlobalKnownHostsFile=/dev/null \
		-o StrictHostKeyChecking=accept-new -o UpdateHostKeys=no -o BatchMode=yes \
		-o ControlMaster=no -o ControlPath=none -o ConnectTimeout=5 -o ServerAliveInterval=15 \
		-o LogLevel=ERROR -p "$_lp" "$_lh" "$@"
}

lab_scp() {
	_lr="$1" _lk="$2" _lp="$3"
	shift 3
	_lkh="$(lab_ssh_known "$_lr")"
	env -u SSH_AUTH_SOCK -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never scp -F /dev/null -q \
		-o IdentityAgent=none -o IdentitiesOnly=yes -i "$_lk" -o AddKeysToAgent=no \
		-o UserKnownHostsFile="$_lkh" -o GlobalKnownHostsFile=/dev/null \
		-o StrictHostKeyChecking=accept-new -o UpdateHostKeys=no -o BatchMode=yes \
		-o ControlMaster=no -o ControlPath=none -o ConnectTimeout=5 -o ServerAliveInterval=15 \
		-o LogLevel=ERROR -P "$_lp" "$@"
}
