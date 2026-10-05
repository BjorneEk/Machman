//
//  GuestScriptSSHTests.swift
//  MachmanTests
//
//  The SSH features' edits in the guest user's ~/.ssh (50-ssh, 52-reverse), run for real
//  under every local POSIX shell through GuestScriptHarness. The home is a stand-in under
//  the probe's scratch dir, owned by whoever runs the tests; scripts/guest-regress checks
//  the same as root per distro.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptSSHTests {

	// The Mac's key as the payload serves it, labelled with the harness VM's marker.
	private static let hostKey =
		"ssh-ed25519 AAAAC3ours \(GuestScriptHarness.marker) regression-vm"

	// Lays out a home for the user running the tests and the payload's host key, then runs
	// `body` (which sees $HOME_DIR, $U and $GROUP).
	private static let home = """
		HOME_DIR="$D/home"
		U="$(id -un)"
		GROUP="$(id -gn)"
		mkdir -p "$HOME_DIR/.ssh"
		printf '%s\\n' '\(hostKey)' > "$PAYLOAD_DIR/host_key.pub"

		"""

	// MARK: - authorized_keys (S39)

	// S39: a user's own key whose comment merely contains machman- (bob@machman-debian, the
	// d is hex) is the user's, never another Machman VM's: it stays, and no sweep is said.
	@Test func userKeysThatMentionMachmanAreKept() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.home + #"""
				cat > "$HOME_DIR/.ssh/authorized_keys" <<'K'
				ssh-ed25519 AAAAC3user1 bob@machman-debian
				ssh-ed25519 AAAAC3user2 ci@machman-builder
				ssh-rsa AAAAB3user3 x@machman-2
				ssh-ed25519 AAAAC3user4 me@machman-0123456789abc
				ssh-ed25519 AAAAC3user5 build-machman-fedcba987654
				K
				ssh_act_key
				echo ---
				cat "$HOME_DIR/.ssh/authorized_keys"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(!r.out.contains("removed another Machman VM's key"), "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("""
				---
				ssh-ed25519 AAAAC3user1 bob@machman-debian
				ssh-ed25519 AAAAC3user2 ci@machman-builder
				ssh-rsa AAAAB3user3 x@machman-2
				ssh-ed25519 AAAAC3user4 me@machman-0123456789abc
				ssh-ed25519 AAAAC3user5 build-machman-fedcba987654
				\(Self.hostKey)

				"""), "\(shell): \(r.out)")
		}
	}

	// A cloned disk's key from the source VM — its marker a whole word, space- or
	// tab-separated, after options too — is swept and said so; the user's keys stay.
	@Test func anotherVMsLabelledKeysAreSwept() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.home + #"""
				tab="$(printf '\t')"
				cat > "$HOME_DIR/.ssh/authorized_keys" <<K
				ssh-ed25519 AAAAC3user1 bob@machman-debian
				ssh-ed25519 AAAAC3other machman-fedcba987654 source vm
				ssh-ed25519 AAAAC3tab${tab}machman-aaaaaaaaaaaa${tab}tabbed vm
				from="10.0.0.1" ssh-ed25519 AAAAC3opt machman-bbbbbbbbbbbb opt vm
				K
				ssh_act_key
				echo ---
				cat "$HOME_DIR/.ssh/authorized_keys"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out.contains("removed another Machman VM's key"), "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("""
				---
				ssh-ed25519 AAAAC3user1 bob@machman-debian
				\(Self.hostKey)

				"""), "\(shell): \(r.out)")
		}
	}

	// MARK: - 'ssh mac' (S42)

	// reverse_act on a NAT guest whose ssh-keygen is a stand-in (it writes the pair it is
	// asked for), after `config` became the user's ~/.ssh/config. UI_COLS=1000: the script
	// folds what it says at the terminal's width; these read it whole.
	private static func reverse(config: String) -> String {
		home + #"""
			UI_COLS=1000
			mkdir -p "$D/bin"
			cat > "$D/bin/ssh-keygen" <<'K'
			#!/bin/sh
			while [ $# -gt 1 ]; do [ "$1" = -f ] && f="$2"; shift; done
			printf 'key\n' > "$f"
			printf 'ssh-ed25519 AAAAC3rev machman-0123456789ab-reverse\n' > "$f.pub"
			K
			chmod 755 "$D/bin/ssh-keygen"
			PATH="$D/bin:$PATH"
			OS=Linux
			GATEWAY=192.168.64.1
			CFG="$HOME_DIR/.ssh/config"
			printf '\#(config)' > "$CFG"
			# Scratch files take the directory's group (wheel under /tmp); an edit keeps the
			# file's owner, which a non-root run may only give its own groups.
			chgrp "$GROUP" "$CFG"
			cp "$CFG" "$D/config.orig"
			# What ssh itself makes of 'mac' with only this file.
			resolve() { ssh -G -F "$CFG" mac 2>/dev/null | grep -E '^(hostname|user) ' | sort; }

			"""#
	}

	// S42: ssh takes each option's first value, so a 'Host *' (or Match) the user keeps at
	// the top redirected Machman's appended 'ssh mac' while the run said ready. The block
	// goes first now — and ends in 'Host *', so the user's top-level lines still apply to
	// every host — and a re-run moves an older run's block up; stripping it restores the file.
	@Test func sshMacGoesAheadOfTheUsersDefaults() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.reverse(
				config: #"ServerAliveInterval 30\nHost *\n\tUser me\n\tHostName studio.lan\n"#
			) + #"""
				reverse_act
				resolve
				ssh -G -F "$CFG" other 2>/dev/null | grep -E '^(hostname|serveraliveinterval) ' \
					| sort
				echo ---
				strip_block "$CFG"
				put_block "$CFG" "$MARKER" 'older run'
				reverse_act >/dev/null
				head -n 2 "$CFG"
				strip_block "$CFG"
				cmp -s "$CFG" "$D/config.orig" && echo restored
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[ok] guest -> host ready: 'ssh mac' reaches 192.168.64.1 (Mac) as gustaf
				   It works once you approve this VM in Machman and Remote Login is on.
				hostname 192.168.64.1
				user gustaf
				hostname studio.lan
				serveraliveinterval 30
				---
				# BEGIN \(GuestScriptHarness.marker)
				Host mac
				restored

				""", "\(shell): \(r.out)")
		}
	}

	// The user's own 'Host mac' (any keyword spelling; a "Host Mac" is no such entry — ssh
	// matches 'mac' as typed) is theirs: Machman's block goes after it, and the run says so
	// in a note (the report's Notes) instead of claiming 'ssh mac' is ready.
	@Test func theUsersOwnHostMacKeepsSshMac() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.reverse(
				config: #"Host Mac\n\tUser nobody\nhost="mac" studio\n\tHostName studio.lan\n"#
			) + #"""
				reverse_act > "$D/out" 2>&1
				sed "s|$D|D|g" "$D/out"
				echo ---
				resolve | grep hostname
				head -n 5 "$CFG"
				printf '%s\n' "$NOTE_LINES" | sed "s|$D|D|g"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			let note = "'ssh mac' stays your own entry in D/home/.ssh/config — Machman's "
				+ "'Host mac' after it does not apply"
			#expect(r.out == """
				[!!] \(note)
				   It works once you approve this VM in Machman and Remote Login is on.
				---
				hostname studio.lan
				Host Mac
				\tUser nobody
				host="mac" studio
				\tHostName studio.lan
				# BEGIN \(GuestScriptHarness.marker)
				two-way: \(note)

				""", "\(shell): \(r.out)")
		}
	}
}
