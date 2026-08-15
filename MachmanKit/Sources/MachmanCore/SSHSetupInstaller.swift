//
//  SSHSetupInstaller.swift
//  MachmanCore
//
//  The SSH setup payload (any guest): one self-contained POSIX script that enables the
//  guest's sshd (per-OS: launchctl on macOS — systemsetup is TCC-gated and fails in fresh
//  VMs —, systemctl/OpenRC/sysrc elsewhere, guided-declarative on NixOS), installs the
//  host's public key for the invoking user, optionally prepares guest→host SSH
//  (--two-way), and reports facts back through the writable SSHReport drop-box. The
//  payload is regenerated at every assembly and served READ-ONLY (a writable script would
//  let any guest process swap it before the admin sudo-runs it); only public keys ever
//  cross the share, in either direction. Every artifact the script writes in the guest
//  carries the per-VM marker, so re-runs and --uninstall are exact-match idempotent.
//

import Foundation
import CryptoKit
import SystemConfiguration
import MachmanAPI

enum SSHSetupInstaller {
	// One name everywhere: on-disk payload dirs under the VM AND the directories the
	// guest sees inside the share.
	static let directoryName = SSHSetupInfo.directoryName
	static let reportDirectoryName = SSHSetupInfo.reportDirectoryName
	static let scriptName = SSHSetupInfo.scriptName
	static let scriptVersion = 1

	// The per-VM marker labeling every guest/host-side artifact. Derived from the
	// machine-identity file bytes — stable across renames (the file never moves content),
	// fresh on copies (VMCopier regenerates identity) — never from the VM name.
	static func marker(for config: VMConfig) throws -> String {
		let fm = FileManager.default
		var data = fm.contents(atPath: config.vmIdentifierPath())
		if data?.isEmpty != false {
			data = fm.contents(atPath: config.macMachineIdPath())
		}
		if data?.isEmpty != false {
			_ = try config.getVmIdentifier()   // creates + persists the identity file
			data = fm.contents(atPath: config.vmIdentifierPath())
		}
		guard let bytes = data, !bytes.isEmpty else {
			throw VirtualMachineError.critical(
				"no machine identity to derive \(config.name)'s SSH marker from")
		}
		let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }
			.joined().prefix(12)
		return "machman-\(hex)"
	}

	// The per-VM host→guest keypair, minted lazily (0600, in the 0700 <vmdir>/ssh dir).
	// Returns the public-key line — the only half that ever enters the payload.
	static func ensureKeypair(for config: VMConfig, marker: String) throws -> String {
		let fm = FileManager.default
		let sshDir = config.localURL(file: "ssh")
		try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
		try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
		let keyURL = sshDir.appendingPathComponent("id_ed25519")
		if !fm.fileExists(atPath: keyURL.path) {
			let keygen = Process()
			keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
			keygen.arguments = [
				"-q", "-t", "ed25519", "-N", "", "-C", "\(marker) \(config.name)",
				"-f", keyURL.path,
			]
			try keygen.run()
			keygen.waitUntilExit()
			guard keygen.terminationStatus == 0 else {
				throw VirtualMachineError.critical(
					"ssh-keygen failed (\(keygen.terminationStatus)) for \(config.name)")
			}
		}
		try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
		return try String(contentsOfFile: keyURL.path + ".pub", encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// Writes <vmdir>/SSHSetup/ (script 0755 + public keys + host.env) and the empty
	// writable <vmdir>/SSHReport/; returns both. Regenerated at every assembly.
	@discardableResult
	static func writePayload(for config: VMConfig) throws -> (payload: URL, report: URL) {
		let fm = FileManager.default
		let marker = try marker(for: config)
		// Cache the marker for reset-time cleanup (creates the ssh state on first use).
		if config.ssh?.marker != marker {
			var state = config.ssh ?? SSHConfig()
			state.marker = marker
			config.ssh = state
			try config.saveVMConfig()
		}
		let publicKey = try ensureKeypair(for: config, marker: marker)
		let dir = config.localURL(file: directoryName)
		let report = config.localURL(file: reportDirectoryName)
		try fm.createDirectory(at: dir, withIntermediateDirectories: true)
		try fm.createDirectory(at: report, withIntermediateDirectories: true)
		let scriptURL = dir.appendingPathComponent(scriptName)
		try script(vmName: config.name, marker: marker)
			.write(to: scriptURL, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
		try (publicKey + "\n").write(
			to: dir.appendingPathComponent("host_key.pub"), atomically: true, encoding: .utf8)
		// The host's machine host key: world-readable once Remote Login was ever enabled;
		// absence just skips guest-side pinning (the script tolerates it).
		let machineKeyDest = dir.appendingPathComponent("host_machine_key.pub")
		try? fm.removeItem(at: machineKeyDest)
		if let key = try? String(
			contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8) {
			try? key.write(to: machineKeyDest, atomically: true, encoding: .utf8)
		}
		try hostEnv().write(
			to: dir.appendingPathComponent("host.env"), atomically: true, encoding: .utf8)
		return (dir, report)
	}

	private static func shellQuoted(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	// Facts about the host the guest-side half needs (sourced by the script).
	static func hostEnv() -> String {
		let localHost = SCDynamicStoreCopyLocalHostName(nil) as String?
		return [
			"HOST_USER=\(shellQuoted(NSUserName()))",
			"HOST_NAME=\(shellQuoted(Host.current().localizedName ?? ""))",
			"HOST_LOCAL=\(shellQuoted(localHost.map { $0 + ".local" } ?? ""))",
			"",
		].joined(separator: "\n")
	}

	// The whole installer. Idempotent: key installs dedupe, the guest-side config block
	// is replaced wholesale between marker lines, and --uninstall removes exactly what
	// carries the marker. sshd is never disabled by --uninstall.
	static func script(vmName: String, marker: String) -> String {
		#"""
		#!/bin/sh
		# Machman SSH setup — generated for "\#(vmName)". Do not edit: Machman regenerates
		# this file at every VM start.
		#
		# Enables this guest's SSH server and installs the Machman host's public key for
		# the invoking user. --two-way additionally prepares guest→host SSH (the host side
		# still requires your approval in Machman). Safe to re-run at any time;
		# --uninstall removes everything it installed (the SSH server stays enabled).
		set -eu

		MARKER="\#(marker)"
		SCRIPT_VERSION="\#(scriptVersion)"
		PAYLOAD_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
		REPORT_DIR="$PAYLOAD_DIR/../\#(reportDirectoryName)"

		usage() {
			echo "usage: sudo sh \"$0\" [--two-way | --one-way] [--install] [--uninstall]" >&2
			exit 64
		}

		TWO_WAY=""
		DO_INSTALL=""
		UNINSTALL=""
		for arg in "$@"; do
			case "$arg" in
			--two-way) TWO_WAY=1 ;;
			--one-way) TWO_WAY=0 ;;
			--install) DO_INSTALL=1 ;;
			--uninstall) UNINSTALL=1 ;;
			*) usage ;;
			esac
		done

		if [ "$(id -u)" -ne 0 ]; then
			echo "Please run with sudo:  sudo sh \"$0\" $*" >&2
			exit 1
		fi

		# ----- who asked --------------------------------------------------------------
		OS="$(uname -s)"
		U="${SUDO_USER:-}"
		if [ "$OS" = "Darwin" ] && { [ -z "$U" ] || [ "$U" = "root" ]; }; then
			U="$(echo "show State:/Users/ConsoleUser" | scutil \
				| awk '/Name :/ && ! /loginwindow/ { print $3 }')"
		fi
		if [ -z "$U" ] || [ "$U" = "root" ]; then
			echo "Cannot tell which user to set up — run via sudo from your own account." >&2
			exit 1
		fi
		case "$OS" in
		Darwin)
			HOME_DIR="$(dscl . -read "/Users/$U" NFSHomeDirectory | awk '{print $2}')"
			;;
		*)
			HOME_DIR="$(getent passwd "$U" 2>/dev/null | cut -d: -f6 || true)"
			[ -n "$HOME_DIR" ] || HOME_DIR="$(eval echo "~$U")"
			;;
		esac
		GROUP="$(id -gn "$U")"

		# ----- which guest ------------------------------------------------------------
		ID=""
		ID_LIKE=""
		if [ "$OS" = "Linux" ] && [ -r /etc/os-release ]; then
			. /etc/os-release
		fi
		ID_ALL="$ID $ID_LIKE"
		has_word() {
			case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
		}
		FAMILY=""
		OS_ID=""
		if [ "$OS" = "Darwin" ]; then FAMILY="darwin"; OS_ID="darwin"
		elif [ "$OS" = "FreeBSD" ]; then FAMILY="freebsd"; OS_ID="freebsd"
		elif [ "$ID" = "nixos" ]; then FAMILY="nixos"; OS_ID="$ID"
		elif [ "$ID" = "alpine" ]; then FAMILY="alpine"; OS_ID="$ID"
		elif has_word debian "$ID_ALL"; then FAMILY="debian"; OS_ID="$ID"
		elif has_word arch "$ID_ALL"; then FAMILY="arch"; OS_ID="$ID"
		elif has_word rhel "$ID_ALL" || has_word fedora "$ID_ALL" \
			|| has_word centos "$ID_ALL"; then FAMILY="rhel"; OS_ID="$ID"
		elif has_word suse "$ID_ALL" || has_word opensuse "$ID_ALL"; then
			FAMILY="suse"; OS_ID="$ID"
		elif [ "$OS" = "Linux" ]; then FAMILY="linux-other"; OS_ID="${ID:-linux}"
		else
			echo "Unsupported guest OS: $OS" >&2
			exit 1
		fi
		# systemd-as-PID-1 test (sd_booted): NOT command -v systemctl — Devuan has apt
		# without systemd.
		SYSTEMD=""
		[ -d /run/systemd/system ] && SYSTEMD=1

		# ----- host facts (from the payload) ------------------------------------------
		HOST_USER=""
		HOST_NAME=""
		HOST_LOCAL=""
		[ -r "$PAYLOAD_DIR/host.env" ] && . "$PAYLOAD_DIR/host.env"

		# ----- helpers ----------------------------------------------------------------
		strip_block() {
			[ -f "$1" ] || return 0
			tmp="$1.machman-tmp"
			awk -v m="$MARKER" '
				$0 == "# BEGIN " m { skip = 1; next }
				$0 == "# END " m { skip = 0; next }
				!skip { print }
			' "$1" > "$tmp"
			mv "$tmp" "$1"
		}

		GATEWAY=""
		IP=""
		find_addresses() {
			case "$OS" in
			Darwin|FreeBSD)
				GATEWAY="$(route -n get default 2>/dev/null \
					| awk '/gateway:/{print $2; exit}' || true)"
				IF="$(route -n get default 2>/dev/null \
					| awk '/interface:/{print $2; exit}' || true)"
				if [ "$OS" = "Darwin" ] && [ -n "$IF" ]; then
					IP="$(ipconfig getifaddr "$IF" 2>/dev/null || true)"
				elif [ -n "$IF" ]; then
					IP="$(ifconfig "$IF" 2>/dev/null \
						| awk '/inet /{print $2; exit}' || true)"
				fi
				;;
			Linux)
				GATEWAY="$(ip route show default 2>/dev/null | awk \
					'{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}' || true)"
				if [ -n "$GATEWAY" ]; then
					IP="$(ip route get "$GATEWAY" 2>/dev/null | awk \
						'{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
				fi
				;;
			esac
		}

		GUEST_HOST_KEY=""
		REVERSE_PUBKEY=""
		write_report() {
			if [ ! -d "$REPORT_DIR" ] || [ ! -w "$REPORT_DIR" ]; then
				echo "warning: cannot write the report back to Machman — the app will" \
					"not learn this guest's address" >&2
				return 0
			fi
			{
				printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
				printf 'MARKER=%s\n' "$MARKER"
				printf 'OS_ID=%s\n' "$OS_ID"
				printf 'USER=%s\n' "$U"
				printf 'HOME=%s\n' "$HOME_DIR"
				printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null || true)"
				printf 'IP=%s\n' "$IP"
				printf 'GATEWAY=%s\n' "$GATEWAY"
				printf 'TWO_WAY=%s\n' "${TWO_WAY:-0}"
				[ -n "$GUEST_HOST_KEY" ] && printf 'HOST_KEY=%s\n' "$GUEST_HOST_KEY"
				[ -n "$REVERSE_PUBKEY" ] && printf 'REVERSE_PUBKEY=%s\n' "$REVERSE_PUBKEY"
				[ -n "${1:-}" ] && printf 'UNINSTALLED=1\n'
				:
			} > "$REPORT_DIR/report.env.tmp"
			mv "$REPORT_DIR/report.env.tmp" "$REPORT_DIR/report.env"
		}

		# ----- uninstall --------------------------------------------------------------
		if [ -n "$UNINSTALL" ]; then
			ak="$HOME_DIR/.ssh/authorized_keys"
			if [ -f "$ak" ]; then
				tmp="$ak.machman-tmp"
				grep -vF "$MARKER" "$ak" > "$tmp" || true
				mv "$tmp" "$ak"
				chown "$U:$GROUP" "$ak"
				chmod 600 "$ak"
			fi
			[ -f "$HOME_DIR/.ssh/config" ] && strip_block "$HOME_DIR/.ssh/config"
			rm -f "$HOME_DIR/.ssh/machman_host" "$HOME_DIR/.ssh/machman_host.pub" \
				"$HOME_DIR/.ssh/machman_known_hosts"
			find_addresses
			write_report uninstalled
			echo "done — Machman's SSH artifacts removed. The SSH server itself was left"
			echo "enabled; disable it yourself if you no longer want it."
			exit 0
		fi

		# ----- one-way or two-way? ----------------------------------------------------
		if [ -z "$TWO_WAY" ]; then
			if [ -t 0 ]; then
				printf "Also set up guest → host SSH back to the Mac? [y/N] "
				read -r answer || answer=""
				case "$answer" in
				y|Y|yes|YES) TWO_WAY=1 ;;
				*) TWO_WAY=0 ;;
				esac
			else
				TWO_WAY=0
			fi
		fi

		# ----- enable sshd ------------------------------------------------------------
		ensure_sshd_installed() {
			if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
				return 0
			fi
			if [ -n "$DO_INSTALL" ]; then
				echo "installing the SSH server:  $1"
				$1
			else
				echo "The SSH server is not installed. Install it first:" >&2
				echo "    sudo $1" >&2
				echo "(or re-run this script with --install to let it do that)" >&2
				exit 1
			fi
		}

		case "$FAMILY" in
		darwin)
			# The systemsetup remote-login toggle is Full-Disk-Access-gated and FAILS in
			# a fresh VM; launchd control is not TCC-gated and persists across boots.
			if ! launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
				launchctl enable system/com.openssh.sshd
				launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist \
					2>/dev/null || true
			fi
			# macOS mints host keys at the first CONNECTION — create them now instead.
			[ -f /etc/ssh/ssh_host_ed25519_key.pub ] || ssh-keygen -A
			;;
		freebsd)
			sysrc sshd_enable=YES >/dev/null
			service sshd start >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1 || true
			;;
		alpine)
			ensure_sshd_installed "apk add openssh"
			rc-update add sshd default >/dev/null 2>&1 || true
			rc-service sshd start >/dev/null 2>&1 \
				|| rc-service sshd restart >/dev/null 2>&1 || true
			;;
		nixos)
			cat <<'NIXOS'
		NixOS is declarative — this script cannot enable sshd here. Add to your
		configuration.nix and rebuild:

		    services.openssh.enable = true;

		then:    sudo nixos-rebuild switch

		Your key is still installed below (NixOS honors ~/.ssh/authorized_keys once
		sshd is enabled).
		NIXOS
			;;
		debian|arch|rhel|suse|linux-other)
			case "$FAMILY" in
			debian) ensure_sshd_installed "apt-get install -y openssh-server" ;;
			arch) ensure_sshd_installed "pacman -S --noconfirm openssh" ;;
			rhel) ensure_sshd_installed "dnf install -y openssh-server" ;;
			suse) ensure_sshd_installed "zypper install -y openssh" ;;
			esac
			unit="sshd"
			[ "$FAMILY" = "debian" ] && unit="ssh"
			if [ -n "$SYSTEMD" ]; then
				systemctl enable --now "$unit"
			else
				echo "warning: no systemd — enable the '$unit' service with your init" \
					"system yourself" >&2
			fi
			if [ "$FAMILY" = "suse" ] && command -v firewall-cmd >/dev/null 2>&1; then
				# openSUSE's firewall blocks port 22 by default on desktop roles.
				firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
				firewall-cmd --reload >/dev/null 2>&1 || true
			fi
			;;
		esac

		# ----- install the host's key ---------------------------------------------------
		key="$(cat "$PAYLOAD_DIR/host_key.pub")"
		mkdir -p "$HOME_DIR/.ssh"
		touch "$HOME_DIR/.ssh/authorized_keys"
		if ! grep -qF "$key" "$HOME_DIR/.ssh/authorized_keys"; then
			printf '%s\n' "$key" >> "$HOME_DIR/.ssh/authorized_keys"
		fi
		chown "$U:$GROUP" "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/authorized_keys"
		chmod 700 "$HOME_DIR/.ssh"
		chmod 600 "$HOME_DIR/.ssh/authorized_keys"
		# SELinux (rhel-family, Leap 16): a root-written authorized_keys can land with the
		# wrong context and be silently refused — exactly what ssh-copy-id fixes up.
		if command -v restorecon >/dev/null 2>&1; then
			restorecon -R "$HOME_DIR/.ssh" 2>/dev/null || true
		fi

		# ----- collect facts ------------------------------------------------------------
		find_addresses
		if [ "$FAMILY" != "nixos" ] && [ ! -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
			ssh-keygen -A 2>/dev/null || true
		fi
		if [ -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
			GUEST_HOST_KEY="$(cat /etc/ssh/ssh_host_ed25519_key.pub)"
		fi

		# ----- guest → host (two-way) ---------------------------------------------------
		if [ "$TWO_WAY" = "1" ]; then
			sshdir="$HOME_DIR/.ssh"
			keyfile="$sshdir/machman_host"
			if [ ! -f "$keyfile" ]; then
				ssh-keygen -q -t ed25519 -N "" -C "$MARKER-reverse" -f "$keyfile"
			fi
			REVERSE_PUBKEY="$(cat "$keyfile.pub")"
			host_target="$GATEWAY"
			if [ "$OS" = "Darwin" ] && [ -n "$HOST_LOCAL" ]; then
				# Bonjour name survives NAT-subnet renumbering; macOS guests resolve it.
				host_target="$HOST_LOCAL"
			fi
			# Pin the Mac's host key so the first guest→host connect has no TOFU prompt.
			known=""
			if [ -r "$PAYLOAD_DIR/host_machine_key.pub" ] && [ -n "$host_target" ]; then
				hk="$(awk '{print $1" "$2}' "$PAYLOAD_DIR/host_machine_key.pub")"
				known="$sshdir/machman_known_hosts"
				{
					[ -n "$GATEWAY" ] && printf '%s %s\n' "$GATEWAY" "$hk"
					[ -n "$HOST_LOCAL" ] && printf '%s %s\n' "$HOST_LOCAL" "$hk"
					:
				} > "$known"
				chown "$U:$GROUP" "$known"
				chmod 600 "$known"
			fi
			if [ -n "$host_target" ]; then
				config="$sshdir/config"
				touch "$config"
				strip_block "$config"
				{
					printf '# BEGIN %s\n' "$MARKER"
					printf 'Host mac\n'
					printf '\tHostName %s\n' "$host_target"
					printf '\tUser %s\n' "$HOST_USER"
					printf '\tIdentityFile %s\n' "$keyfile"
					printf '\tIdentitiesOnly yes\n'
					[ -n "$known" ] && printf '\tUserKnownHostsFile %s\n' "$known"
					printf '# END %s\n' "$MARKER"
				} > "$config.machman-block"
				cat "$config.machman-block" >> "$config"
				rm -f "$config.machman-block"
				chown "$U:$GROUP" "$config"
				chmod 600 "$config"
				echo "guest → host: 'ssh mac' will work once you approve this VM in" \
					"Machman (and the Mac's Remote Login is on)."
			else
				echo "warning: no route to the host found — guest → host config skipped" >&2
			fi
			chown "$U:$GROUP" "$keyfile" "$keyfile.pub"
			chmod 600 "$keyfile"
		fi

		# ----- report back --------------------------------------------------------------
		write_report

		echo ""
		echo "done — SSH is set up for $U."
		if [ -n "$IP" ]; then
			echo "From your Mac:    ssh $U@$IP"
		fi
		echo "Machman shows this VM's live address in the Network device's inspector."
		"""#
	}
}
