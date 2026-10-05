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
}
