# === machman-setup: 52-reverse ===
# Feature: guest -> host SSH back to the Mac ('ssh mac'), the link sshfs mounts ride.
# Needs approval in Machman before it works; only public keys ever cross the share.

REVERSE_PLAN=""
avail_reverse=0
reason_reverse=""

reverse_detect() {
	return 0
}

# The key lives in the installed user's home; at menu time that is the marker's owner.
reverse_is_configured() {
	_ric_h=""
	[ -n "$SSH_INSTALLED_USER" ] && _ric_h="$(home_of "$SSH_INSTALLED_USER")"
	[ -z "$_ric_h" ] && [ -n "$HOME_DIR" ] && _ric_h="$HOME_DIR"
	# The comment pins the owner: a cloned guest's key carries the source VM's marker
	# and does not count — reverse_act replaces it.
	[ -n "$_ric_h" ] && [ -f "$_ric_h/.ssh/machman_host" ] \
		&& grep -qF "$MARKER-reverse" "$_ric_h/.ssh/machman_host.pub" 2>/dev/null
}

reverse_menu_note() {
	if reverse_is_configured; then
		echo "configured — verify ('ssh mac' entry refreshed)"
	else
		echo "enables 'ssh mac' and sshfs mounts"
	fi
	return 0
}

reverse_menu_default() {
	# Opt-in — except a re-run keeps what is configured fresh.
	if reverse_is_configured || state_was_configured reverse; then echo 1; else echo 0; fi
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
	_rd_verb="set up"
	reverse_is_configured && _rd_verb="verify"
	if [ -n "$GATEWAY" ] || { [ "$OS" = Darwin ] && [ -n "$HOST_LOCAL" ]; }; then
		REVERSE_PLAN="$_rd_verb: ssh mac -> ${GATEWAY:-$HOST_LOCAL} as $HOST_USER (needs approval in Machman)"
	else
		REVERSE_PLAN="$_rd_verb: key prepared; no route to the Mac yet"
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
	if [ -f "$_atw_key" ] \
		&& ! grep -qF "$MARKER-reverse" "$_atw_key.pub" 2>/dev/null; then
		rm -f "$_atw_key" "$_atw_key.pub"
		ok "replaced another Machman VM's guest key (cloned guest)"
	fi
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
	_atw_body="$(
		printf 'Host mac\n\tHostName %s\n\tUser %s\n' "$_atw_target" "$HOST_USER"
		printf '\tIdentityFile %s\n\tIdentitiesOnly yes\n' "$_atw_key"
		[ -n "$_atw_known" ] && printf '\tUserKnownHostsFile %s\n' "$_atw_known"
		:
	)"
	chown "$U:$GROUP" "$_atw_key" "$_atw_key.pub"
	chmod 600 "$_atw_key"
	# A new config is the user's own, 0600; an existing one keeps its owner and mode.
	if ! put_block -m 600 -o "$U:$GROUP" "$_atw_dir/config" "$MARKER" "$_atw_body"; then
		step_failed two-way "'ssh mac' was not added: $R_ERROR" \
			"Add a 'Host mac' entry to it yourself (IdentityFile $_atw_key)."
		return 0
	fi
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
	# The same multi-user rule as ssh_uninstall: the keypair lives where install put it,
	# not where detect_user points today. Only OUR key comes off (the marker comment
	# names it) — a foreign-marker keypair belongs to another Machman VM.
	for _ru_u in $(ssh_touched_users); do
		_ru_h="$(home_of "$_ru_u")"
		[ -n "$_ru_h" ] || continue
		strip_block "$_ru_h/.ssh/config" || uninstall_kept
		if grep -qF "$MARKER-reverse" "$_ru_h/.ssh/machman_host.pub" 2>/dev/null; then
			rm -f "$_ru_h/.ssh/machman_host" "$_ru_h/.ssh/machman_host.pub" \
				"$_ru_h/.ssh/machman_known_hosts"
			ok "removed the guest -> host key from $_ru_u"
		fi
	done
	return 0
}
