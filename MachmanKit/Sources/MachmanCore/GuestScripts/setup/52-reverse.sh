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

# Whether the user's own config — outside every Machman block — has a Host line naming mac:
# their 'ssh mac', which Machman never takes over. The keyword is any case, the pattern is
# not (ssh matches 'mac' as typed: a "Host Mac" never catches it). <config>
reverse_user_owns_mac() {
	regular_file "$1" || return 1
	awk '
		/^# BEGIN machman-/ { inb = 1; next }
		/^# END machman-/ { inb = 0; next }
		inb { next }
		match($0, /^[ \t]*[Hh][Oo][Ss][Tt]([ \t]*=[ \t]*|[ \t]+)/) {
			n = split(substr($0, RLENGTH + 1), pats, /[ \t]+/)
			for (i = 1; i <= n; i++) {
				p = pats[i]
				gsub(/"/, "", p)
				if (p == "mac") found = 1
			}
		}
		END { exit found ? 0 : 1 }' "$1"
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
	if ! ssh_dir_ready "$HOME_DIR" "$U" "$GROUP"; then
		step_failed two-way "guest -> host SSH was not set up: $R_ERROR" \
			"Make it a plain directory owned by $U, then re-run."
		return 0
	fi
	# Links where our files go were planted, never made by us: they go (rm never follows).
	for _atw_f in "$_atw_key" "$_atw_key.pub" "$_atw_dir/machman_known_hosts"; do
		if [ -L "$_atw_f" ]; then rm -f "$_atw_f"; fi
	done
	if [ -e "$_atw_key" ] && ! { regular_file "$_atw_key.pub" \
		&& grep -qF "$MARKER-reverse" "$_atw_key.pub"; }; then
		rm -f "$_atw_key" "$_atw_key.pub"
		ok "replaced another Machman VM's guest key (cloned guest)"
	fi
	if ! regular_file "$_atw_key" || ! regular_file "$_atw_key.pub"; then
		# Minted in a directory only root can enter, then moved in by write_file:
		# ssh-keygen itself would write through whatever stands at its -f path.
		_atw_tmpd="$(mktemp -d)" \
			|| die 1 "could not make a temporary directory for the guest's key"
		if ! run "creating the guest's key" ssh-keygen -q -t ed25519 -N "" \
			-C "$MARKER-reverse" -f "$_atw_tmpd/key"; then
			rm -rf "$_atw_tmpd"
			die 1 "ssh-keygen could not create the guest's key${R_ERROR:+: $R_ERROR}" \
				"Check that ssh-keygen works, then re-run."
		fi
		_atw_ok=0
		write_file -m 600 -o "$U:$GROUP" "$_atw_key" < "$_atw_tmpd/key" \
			&& write_file -m 644 -o "$U:$GROUP" "$_atw_key.pub" < "$_atw_tmpd/key.pub" \
			|| _atw_ok=1
		rm -rf "$_atw_tmpd"
		if [ "$_atw_ok" -ne 0 ]; then
			step_failed two-way "could not store the guest's key: $R_ERROR" \
				"Check $_atw_dir, then re-run."
			return 0
		fi
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
		return 0
	fi
	# Pin the Mac's host key so the first guest -> host connect has no TOFU prompt.
	_atw_known=""
	if [ -r "$PAYLOAD_DIR/host_machine_key.pub" ]; then
		_atw_hk="$(awk '{ print $1" "$2 }' "$PAYLOAD_DIR/host_machine_key.pub")"
		_atw_known="$_atw_dir/machman_known_hosts"
		_atw_lines="$(
			[ -n "$GATEWAY" ] && printf '%s %s\n' "$GATEWAY" "$_atw_hk"
			[ -n "$HOST_LOCAL" ] && printf '%s %s\n' "$HOST_LOCAL" "$_atw_hk"
			:
		)"
		# A here-doc, not a pipe: write_file runs in this shell, so a refusal clears it.
		write_file -m 600 -o "$U:$GROUP" "$_atw_known" <<EOF || _atw_known=""
$_atw_lines
EOF
	fi
	# The block ends back at every host: what follows it is the user's, for all of them. (No
	# apostrophes in comments inside $( ): macOS's bash 3.2 sh reads them as quotes.)
	_atw_body="$(
		printf 'Host mac\n\tHostName %s\n\tUser %s\n' "$_atw_target" "$HOST_USER"
		printf '\tIdentityFile %s\n\tIdentitiesOnly yes\n' "$_atw_key"
		[ -n "$_atw_known" ] && printf '\tUserKnownHostsFile %s\n' "$_atw_known"
		printf 'Host *\n'
	)"
	# ssh takes each option's first value, so the block goes first: no Host * or Match of
	# the user's can redirect 'ssh mac'. Their own 'Host mac' keeps it, though — ours goes
	# after it, said so. A new config is the user's own, 0600; an existing one keeps its
	# owner and mode.
	_atw_top=-t
	reverse_user_owns_mac "$_atw_dir/config" && _atw_top=""
	if ! put_block -m 600 -o "$U:$GROUP" ${_atw_top:+"$_atw_top"} "$_atw_dir/config" \
		"$MARKER" "$_atw_body"; then
		step_failed two-way "'ssh mac' was not added: $R_ERROR" \
			"Add a 'Host mac' entry to it yourself (IdentityFile $_atw_key)."
		return 0
	fi
	if [ -z "$_atw_top" ]; then
		report_note two-way "'ssh mac' stays your own entry in $_atw_dir/config — Machman's 'Host mac' after it does not apply"
	else
		ok "guest -> host ready: 'ssh mac' reaches ${_atw_target}${HOST_NAME:+ ($HOST_NAME)} as $HOST_USER"
	fi
	note "It works once you approve this VM in Machman and Remote Login is on."
	return 0
}

reverse_report() {
	printf 'TWO_WAY=1\n'
	[ -n "$REVERSE_PUBKEY" ] && printf 'REVERSE_PUBKEY=%s\n' "$REVERSE_PUBKEY"
	return 0
}

# The guest -> host key is this VM's (its marker in the comment) or a source's this copy
# took over (a copy makes its own key, so a source's stays only until its first run).
reverse_key_ours() {
	grep -qF "$MARKER-reverse" "$1" && return 0
	for _rko_m in $(ledger_values adopted); do
		grep -qF "$_rko_m-reverse" "$1" && return 0
	done
	return 1
}

reverse_uninstall() {
	# The same multi-user rule as ssh_uninstall: the keypair lives where install put it,
	# not where detect_user points today. Only OUR key comes off (the marker comment
	# names it: this VM's, or a source's it took over) — any other belongs to another VM.
	for _ru_u in $(ssh_touched_users); do
		_ru_h="$(home_of "$_ru_u")"
		[ -n "$_ru_h" ] || continue
		strip_block "$_ru_h/.ssh/config" || uninstall_kept
		if regular_file "$_ru_h/.ssh/machman_host.pub" \
			&& reverse_key_ours "$_ru_h/.ssh/machman_host.pub"; then
			rm -f "$_ru_h/.ssh/machman_host" "$_ru_h/.ssh/machman_host.pub" \
				"$_ru_h/.ssh/machman_known_hosts"
			ok "removed the guest -> host key from $_ru_u"
		fi
	done
	return 0
}
