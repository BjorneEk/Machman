# === machman-setup: 52-reverse ===
# Feature: guest -> host SSH back to the Mac ('ssh mac'), the link sshfs mounts ride.
# Needs approval in Machman before it works; only public keys ever cross the share.

REVERSE_PLAN=""
avail_reverse=0
reason_reverse=""

reverse_detect() {
	return 0
}

reverse_available() {
	avail_reverse=0
	reason_reverse=""
	if ! have ssh-keygen; then
		reason_reverse="ssh-keygen is missing — install the OpenSSH client"
		return 0
	fi
	avail_reverse=1
	return 0
}

reverse_decide() {
	if [ -n "$GATEWAY" ] || { [ "$OS" = Darwin ] && [ -n "$HOST_LOCAL" ]; }; then
		REVERSE_PLAN="ssh mac -> ${GATEWAY:-$HOST_LOCAL} as $HOST_USER (needs approval in Machman)"
	else
		REVERSE_PLAN="key prepared; no route to the Mac yet"
	fi
	return 0
}

reverse_plan() {
	plan_line "guest -> host" "$REVERSE_PLAN"
	return 0
}

reverse_act() {
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

reverse_report() {
	printf 'TWO_WAY=1\n'
	[ -n "$REVERSE_PUBKEY" ] && printf 'REVERSE_PUBKEY=%s\n' "$REVERSE_PUBKEY"
	return 0
}

reverse_uninstall() {
	[ -f "$HOME_DIR/.ssh/config" ] && strip_block "$HOME_DIR/.ssh/config"
	rm -f "$HOME_DIR/.ssh/machman_host" "$HOME_DIR/.ssh/machman_host.pub" \
		"$HOME_DIR/.ssh/machman_known_hosts"
	return 0
}
