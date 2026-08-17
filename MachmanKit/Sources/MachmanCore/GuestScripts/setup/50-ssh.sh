# === machman-setup: 50-ssh ===
# Feature: Mac -> guest SSH — enable this guest's sshd and install the Mac's public key
# for one user. The proven v2 recipes, feature-shaped.

SSHD_PLAN=""
F_AVAIL_ssh=0
F_REASON_ssh=""

ssh_detect() {
	detect_sshd
	return 0
}

ssh_available() {
	F_AVAIL_ssh=0
	F_REASON_ssh=""
	if [ ! -r "$PAYLOAD_DIR/host_key.pub" ]; then
		F_REASON_ssh="the Mac's public key is missing from the payload — restart the VM"
		return 0
	fi
	F_AVAIL_ssh=1
	return 0
}

ssh_decide() {
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

ssh_plan() {
	plan_line "user" "$U -> $HOME_DIR"
	plan_line "ssh server" "$SSHD_PLAN"
	plan_line "host key" "the Mac's key -> $HOME_DIR/.ssh/authorized_keys"
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

ssh_act_nixos() {
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

ssh_act_key() {
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
	if [ "$OS_FAMILY" != nixos ] && [ ! -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
		ssh-keygen -A 2>/dev/null || true
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
	_su_ak="$HOME_DIR/.ssh/authorized_keys"
	if [ -f "$_su_ak" ]; then
		_su_tmp="$_su_ak.machman-tmp"
		grep -vF "$MARKER" "$_su_ak" > "$_su_tmp" || true
		mv "$_su_tmp" "$_su_ak"
		chown "$U:$GROUP" "$_su_ak"
		chmod 600 "$_su_ak"
	fi
	if [ "$OS_FAMILY" = nixos ] && [ -f /etc/nixos/configuration.nix ] \
		&& grep -q "# $MARKER" /etc/nixos/configuration.nix; then
		_su_tmp="/etc/nixos/configuration.nix.machman-tmp"
		grep -v "# $MARKER" /etc/nixos/configuration.nix > "$_su_tmp"
		mv "$_su_tmp" /etc/nixos/configuration.nix
		note "removed the Machman line from configuration.nix — run 'nixos-rebuild switch'."
	fi
	return 0
}
