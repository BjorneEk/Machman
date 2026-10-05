# === machman-setup: 50-ssh ===
# Feature: Mac -> guest SSH — enable this guest's sshd and install the Mac's public key
# for one user. The proven v2 recipes, feature-shaped and ownership-aware: the marker in
# the key's comment tells us WHO it is installed for, so the plan can say "verify" or
# "switch gustaf -> bob" instead of a generic install line.

SSHD_PLAN=""
KEY_PLAN=""
SSH_INSTALLED_USER=""      # who carries the Mac's marker-tagged key already, if anyone
SSH_SWITCH_FROM=""         # remove that user's key after installing for the new one
avail_ssh=0
reason_ssh=""

# A Machman VM's key carries that VM's marker as a whole word: machman- and exactly 12 hex
# digits (SSHSetupInstaller's label), so a user's own bob@machman-debian is never one. The
# digits are spelled out — older awks have no {12}. An ERE for awk -v and grep -E alike.
_skl_hex='[0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
_skl_gap="[ $(printf '\t')]"
SSH_LABEL_ERE="(^|$_skl_gap)machman-$_skl_hex$_skl_hex$_skl_hex($_skl_gap|\$)"

# Marker-scan the candidate homes (state first — it is cheaper and usually right).
ssh_find_installed_user() {
	SSH_INSTALLED_USER=""
	if [ -n "$ST_SSH_USER" ]; then
		_sfu_h="$(home_of "$ST_SSH_USER")"
		if [ -n "$_sfu_h" ] \
			&& grep -qF "$MARKER" "$_sfu_h/.ssh/authorized_keys" 2>/dev/null; then
			SSH_INSTALLED_USER="$ST_SSH_USER"
			return 0
		fi
	fi
	for _sfu_u in $(candidate_users) root; do
		_sfu_h="$(home_of "$_sfu_u")"
		[ -n "$_sfu_h" ] || continue
		if grep -qF "$MARKER" "$_sfu_h/.ssh/authorized_keys" 2>/dev/null; then
			SSH_INSTALLED_USER="$_sfu_u"
			return 0
		fi
	done
	return 0
}

ssh_detect() {
	detect_sshd
	ssh_find_installed_user
	verbose detect "ssh installed-for=${SSH_INSTALLED_USER:-nobody}"
	return 0
}

# Every user whose home an install may have touched: today's pick, the state file's
# record, the candidate scan, and root. Deduplicated, one per line — the uninstall
# sweeps ALL of them, because install can leave keys behind for more than one user.
ssh_touched_users() {
	_stu_seen=""
	for _stu_u in "$U" "$ST_SSH_USER" $(candidate_users) root; do
		[ -n "$_stu_u" ] || continue
		if has_word "$_stu_u" "$_stu_seen"; then continue; fi
		_stu_seen="$_stu_seen $_stu_u"
		printf '%s\n' "$_stu_u"
	done
	return 0
}

ssh_is_configured() {
	[ -n "$SSH_INSTALLED_USER" ]
}

ssh_menu_note() {
	if [ -n "$SSH_INSTALLED_USER" ]; then
		echo "key installed for $SSH_INSTALLED_USER — verify"
	elif [ "$SSHD" = running ]; then
		echo "sshd running — install the Mac's key"
	elif [ "$SSHD" = installed ]; then
		echo "enable sshd, install the Mac's key"
	else
		echo "install sshd and the Mac's key"
	fi
	return 0
}

ssh_menu_default() {
	echo 1
	return 0
}

ssh_available() {
	avail_ssh=0
	reason_ssh=""
	if [ ! -r "$PAYLOAD_DIR/host_key.pub" ]; then
		reason_ssh="the Mac's public key is missing from the payload — restart the VM"
		return 0
	fi
	avail_ssh=1
	return 0
}

ssh_decide() {
	# The key verb: verify, switch, or install — decided against the marker's owner.
	SSH_SWITCH_FROM=""
	if [ -n "$SSH_INSTALLED_USER" ] && [ "$SSH_INSTALLED_USER" = "$U" ]; then
		KEY_PLAN="already installed for $U — verify"
	elif [ -n "$SSH_INSTALLED_USER" ]; then
		ask_yes_no "Move SSH from $SSH_INSTALLED_USER to $U (removes $SSH_INSTALLED_USER's Machman key)?" y
		if [ "$R_YES" = 1 ]; then
			SSH_SWITCH_FROM="$SSH_INSTALLED_USER"
			KEY_PLAN="switch $SSH_INSTALLED_USER -> $U"
		else
			KEY_PLAN="install for $U ($SSH_INSTALLED_USER keeps the key too)"
		fi
	else
		KEY_PLAN="the Mac's key -> $HOME_DIR/.ssh/authorized_keys"
	fi
	if [ "$NO_SERVICE" -eq 1 ]; then
		SSHD_PLAN="left alone (--no-service)"
		return 0
	fi
	# NixOS: the service is a configuration.nix setting whether or not the openssh
	# package (and with it an sshd binary) is on PATH — only a running sshd is done.
	if [ "$OS_FAMILY" = nixos ] && [ "$SSHD" != running ]; then
		SSHD_PLAN="declarative — configuration.nix + rebuild"
		if [ -z "$DO_INSTALL" ]; then
			ask_yes_no "Add services.openssh to /etc/nixos/configuration.nix and rebuild?" n
			DO_INSTALL="$R_YES"
		fi
		[ "$DO_INSTALL" = 1 ] || SSHD_PLAN="NOT enabled — NixOS needs a config change"
		return 0
	fi
	if [ "$SSHD" = missing ]; then
		_ds_pkgs="$(pkg_for_sshd)"
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

ssh_plan() {
	plan_line "user" "$U -> $HOME_DIR"
	plan_line "ssh server" "$SSHD_PLAN"
	plan_line "host key" "$KEY_PLAN"
	return 0
}

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
	netbsd-rc)
		rc_conf_yes sshd || return 1
		run "starting sshd" /etc/rc.d/sshd start || run "restarting sshd" /etc/rc.d/sshd restart \
			|| true
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
	inittab|sysv)
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

# rc_conf_yes <name> [file] — <name>=YES as the file's last word on <name> (rc.conf is
# read top to bottom; default /etc/rc.conf), appended when it is not. Unmarked, like
# FreeBSD's sysrc, and kept by the uninstall: the SSH server stays.
rc_conf_yes() {
	_rcy_file="${2:-/etc/rc.conf}"
	STEP="enabling $1 in $_rcy_file"
	if [ -f "$_rcy_file" ] && awk -v n="$1" -v q="'" '
		{ sub(/#.*/, "") }
		$0 ~ "^[ \t]*" n "=" { v = $0; sub("^[ \t]*" n "=", "", v); gsub("[\"" q " \t]", "", v) }
		END { if (toupper(v) == "YES") exit 0; exit 1 }' "$_rcy_file"; then
		return 0
	fi
	_MF_TEXT="$1=YES"
	export _MF_TEXT
	_rcy_code=0
	if [ -f "$_rcy_file" ]; then
		rewrite_file "$_rcy_file" awk '{ print } END { print ENVIRON["_MF_TEXT"] }' \
			|| _rcy_code=$?
	else
		# A here-doc, not a pipe: write_file must run in this shell to hand back R_ERROR.
		write_file "$_rcy_file" <<EOF || _rcy_code=$?
$_MF_TEXT
EOF
	fi
	unset _MF_TEXT
	return "$_rcy_code"
}

# Filter for configuration.nix: our marked services.openssh line, inside the final brace.
ssh_nixos_filter() {
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
		}'
}

ssh_act_nixos() {
	if sshd_active; then
		ok "sshd is already enabled (declaratively) — nothing to change"
		return 0
	fi
	# Only a SETTING counts as the user's own: the stock template's commented-out
	# "# services.openssh.enable = true;" is not one, and neither is our marked line
	# (a rebuild that failed last time is simply retried).
	if [ "$DO_INSTALL" != 1 ] || ! regular_file /etc/nixos/configuration.nix \
		|| grep -v "# $MARKER\$" /etc/nixos/configuration.nix \
			| grep -q '^[[:space:]]*services\.openssh'; then
		step_failed sshd "NixOS is declarative — sshd cannot be enabled from a script here" \
			"Add 'services.openssh.enable = true;' to /etc/nixos/configuration.nix, run 'nixos-rebuild switch', then re-run. Your key is installed either way."
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add services.openssh to configuration.nix and rebuild"
		return 0
	fi
	# One marked line inside the final brace, backed up first.
	if ! grep -q "# $MARKER\$" /etc/nixos/configuration.nix; then
		if ! write_file /etc/nixos/configuration.nix.machman-backup \
			< /etc/nixos/configuration.nix \
			|| ! rewrite_file /etc/nixos/configuration.nix ssh_nixos_filter; then
			step_failed sshd "could not edit configuration.nix: $R_ERROR" \
				"Add 'services.openssh.enable = true;' to it yourself and rebuild."
			return 0
		fi
	fi
	if run_live "rebuilding NixOS (slow)" nixos-rebuild switch; then
		ok "sshd enabled in configuration.nix and rebuilt"
	else
		step_failed sshd "nixos-rebuild failed — configuration.nix keeps the Machman line" \
			"Fix the error it printed and run 'nixos-rebuild switch' yourself."
	fi
	return 0
}

# <home>/.ssh as the user's own real directory, 0700 (created when missing). A link there
# is refused, never followed: root is about to write and chown inside it.
# ssh_dir_ready <home> <user> <group>
ssh_dir_ready() {
	R_ERROR=""
	if [ -L "$1/.ssh" ]; then
		R_ERROR="$1/.ssh is a symbolic link"
		return 1
	fi
	if [ ! -e "$1/.ssh" ] && ! mkdir -p -m 700 "$1/.ssh" 2>/dev/null; then
		R_ERROR="could not create $1/.ssh"
		return 1
	fi
	# Pinned: the chown/chmod land on the directory just checked, whatever moves after.
	if ! ( _sdr_up="$(cd -P "$1" && pwd -P)" && cd -P "$1/.ssh" \
		&& [ "$(pwd -P)" = "${_sdr_up%/}/.ssh" ] && chown -h "$2:$3" . && chmod 700 . ) \
		2>/dev/null; then
		R_ERROR="$1/.ssh is not a directory of its own"
		return 1
	fi
	return 0
}

# Filter for authorized_keys: other Machman VMs' keys dropped (a cloned disk's), the
# Mac's key (ENVIRON _MF_BODY) kept, or appended when missing. _MF_TEXT is our marker.
ssh_keys_filter() {
	awk -v re="$SSH_LABEL_ERE" '
		$0 ~ re && index($0, ENVIRON["_MF_TEXT"]) == 0 { next }
		{ print; if (index($0, ENVIRON["_MF_BODY"])) have = 1 }
		END { if (!have) print ENVIRON["_MF_BODY"] }'
}

ssh_act_key() {
	STEP="installing the Mac's key"
	_aik_key="$(cat "$PAYLOAD_DIR/host_key.pub")"
	if [ "$DRY_RUN" -eq 1 ]; then
		acting "would add the Mac's key to $HOME_DIR/.ssh/authorized_keys"
		return 0
	fi
	_aik_ak="$HOME_DIR/.ssh/authorized_keys"
	if ! ssh_dir_ready "$HOME_DIR" "$U" "$GROUP"; then
		step_failed ssh-key "the Mac's key was not installed: $R_ERROR" \
			"Make it a plain directory owned by $U, then re-run."
		return 0
	fi
	if [ ! -e "$_aik_ak" ] && [ ! -L "$_aik_ak" ]; then
		write_file -m 600 -o "$U:$GROUP" "$_aik_ak" </dev/null || true
	fi
	if ! regular_file "$_aik_ak"; then
		_aik_code=13
		[ -L "$_aik_ak" ] && _aik_code=12
		step_failed ssh-key \
			"the Mac's key was not installed: $(_rf_reason "$_aik_code" "$_aik_ak")" \
			"Add host_key.pub from the share to it yourself."
		return 0
	fi
	# A cloned guest disk carries the source VM's machman key. A machman-tagged line
	# whose marker is not ours is stale, not the user's — the rewrite sweeps it.
	_aik_swept=0
	if grep -E "$SSH_LABEL_ERE" "$_aik_ak" | grep -qvF "$MARKER"; then
		_aik_swept=1
	fi
	_aik_had=0
	grep -qF "$_aik_key" "$_aik_ak" && _aik_had=1
	# One rewrite sweeps, installs and repairs what sshd's StrictModes wants (the user's
	# own file, 0600) — so this one does not keep the old owner and mode.
	_MF_TEXT="$MARKER"
	_MF_BODY="$_aik_key"
	export _MF_TEXT _MF_BODY
	_aik_ok=0
	rewrite_file -m 600 -o "$U:$GROUP" "$_aik_ak" ssh_keys_filter || _aik_ok=1
	unset _MF_TEXT _MF_BODY
	if [ "$_aik_ok" -ne 0 ]; then
		step_failed ssh-key "the Mac's key was not installed: $R_ERROR" \
			"Add host_key.pub from the share to it yourself."
		return 0
	fi
	[ "$_aik_swept" -eq 1 ] && ok "removed another Machman VM's key (cloned guest)"
	# SELinux (rhel-family, Leap 16): a root-written authorized_keys can land with the
	# wrong context and be silently refused — exactly what ssh-copy-id fixes up.
	if have restorecon; then
		restorecon -R "$HOME_DIR/.ssh" 2>/dev/null || true
	fi
	if [ "$_aik_had" -eq 1 ]; then
		ok "the Mac's key is verified for $U"
	else
		ok "the Mac's key is installed for $U"
	fi
	# The switch: remove exactly the marker-tagged line from the previous user.
	if [ -n "$SSH_SWITCH_FROM" ] && [ "$SSH_SWITCH_FROM" != "$U" ]; then
		_aik_oh="$(home_of "$SSH_SWITCH_FROM")"
		_aik_oak="$_aik_oh/.ssh/authorized_keys"
		if [ -n "$_aik_oh" ] && [ -f "$_aik_oak" ] \
			&& grep -qF "$MARKER" "$_aik_oak" 2>/dev/null; then
			if drop_lines "$_aik_oak" "$MARKER"; then
				ok "removed the Mac's key from $SSH_SWITCH_FROM"
			else
				step_failed ssh-key \
					"could not remove the Mac's key from $SSH_SWITCH_FROM: $R_ERROR" \
					"Delete the line tagged $MARKER from it yourself."
			fi
		fi
	fi
	return 0
}

ssh_act() {
	if [ "$NO_SERVICE" -eq 0 ]; then
		if [ "$OS_FAMILY" = nixos ]; then
			ssh_act_nixos
		elif [ "$SSHD" = missing ]; then
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
			fi
		fi
		if [ "$OS_FAMILY" != nixos ] && [ "$SSHD" != missing ]; then
			if enable_sshd; then
				ok "sshd is enabled and running"
			else
				step_failed sshd \
					"could not enable the '$SSHD_UNIT' service${R_ERROR:+: $R_ERROR}" \
					"Start it with your init system ($INIT), then re-run."
			fi
			if [ "$OS_FAMILY" = suse ] && have firewall-cmd; then
				# openSUSE's firewall blocks port 22 by default on desktop roles.
				run "opening the firewall for ssh" \
					firewall-cmd --permanent --add-service=ssh || true
				run "reloading the firewall" firewall-cmd --reload || true
			fi
		fi
	fi
	ssh_act_key
	return 0
}

collect_host_key() {
	if [ "$OS_FAMILY" != nixos ] && [ "${REPORT_ONLY:-0}" -eq 0 ] \
		&& [ ! -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
		# Fully silenced: its "generating new host keys" chatter goes to STDOUT, and
		# this can run inside write_report's redirection — straight into report.env.
		ssh-keygen -A >/dev/null 2>&1 || true
	fi
	if [ -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
		GUEST_HOST_KEY="$(cat /etc/ssh/ssh_host_ed25519_key.pub)"
	fi
	return 0
}

ssh_report() {
	collect_host_key
	printf 'SSHD=%s\n' "$SSHD"
	printf 'USER=%s\n' "$U"
	printf 'HOME=%s\n' "$HOME_DIR"
	[ -n "$GUEST_HOST_KEY" ] && printf 'HOST_KEY=%s\n' "$GUEST_HOST_KEY"
	return 0
}

ssh_uninstall() {
	# Install can leave the key for more than one user (the "keeps the key too" branch),
	# and detect_user's pick today need not be who install picked — strip the marker line
	# from EVERY touched home, never just $U's.
	for _su_u in $(ssh_touched_users); do
		_su_h="$(home_of "$_su_u")"
		[ -n "$_su_h" ] || continue
		_su_ak="$_su_h/.ssh/authorized_keys"
		[ -f "$_su_ak" ] && grep -qF "$MARKER" "$_su_ak" 2>/dev/null || continue
		# Owner and mode stay as the user left them.
		if drop_lines "$_su_ak" "$MARKER"; then
			ok "removed the Mac's key from $_su_u"
		else
			uninstall_kept
		fi
	done
	if [ "$OS_FAMILY" = nixos ] && [ -f /etc/nixos/configuration.nix ] \
		&& grep -q "# $MARKER" /etc/nixos/configuration.nix; then
		if drop_lines /etc/nixos/configuration.nix "# $MARKER"; then
			# The strip IS the restore — the install-time backup has nothing left in it.
			rm -f /etc/nixos/configuration.nix.machman-backup
			note "removed the Machman line from configuration.nix — run 'nixos-rebuild switch'."
		else
			uninstall_kept
		fi
	fi
	# Deliberate keep, disclosed: sshd stays (this uninstall may be running over it),
	# and with it openSUSE's permanent firewall opening for ssh.
	if [ "$OS_FAMILY" = suse ] && have firewall-cmd \
		&& firewall-cmd --permanent --query-service=ssh >/dev/null 2>&1; then
		note "the firewall keeps ssh open (sshd stays) — 'firewall-cmd --permanent --remove-service=ssh' reverts it."
	fi
	return 0
}
