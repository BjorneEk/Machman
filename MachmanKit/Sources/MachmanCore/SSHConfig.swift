//
//  SSHConfig.swift
//  MachmanCore
//
//  Persisted SSH state (wire 1.0.6): what the guest's install report taught us plus the
//  user's per-VM switches. Absent from disk until SSH is first used (conditional encode) —
//  and the reason 1.0.6 is the version floor: an older daemon's config rewrite drops the
//  keys it does not know.
//

import Foundation
import MachmanAPI

struct SSHConfig: Codable, Equatable {
	var guestUser: String?
	var guestHostname: String?
	var guestOS: String?
	var guestOSVersion: String?
	var guestHostKey: String?        // "ssh-ed25519 AAAA…" line from the guest's report
	var reversePublicKey: String?    // guest's reverse key — public half only
	// Plain string on disk (the GuestDevice.kind lesson): a value written by a NEWER daemon
	// survives this daemon's load/save cycle verbatim.
	var reverseState: String?
	var integrationEnabled: Bool = false
	var lastReportAt: Date?          // stamped by the host at ingestion
	var marker: String?              // labels guest/host artifacts; never on the wire
	// The ~/.ssh alias the user chose; nil means the default "<vm>.machman". Kept across
	// renames precisely because it was chosen (a default alias follows the name instead).
	var alias: String?
	// The last address the guest reported. The managed ~/.ssh file is otherwise the only
	// memory of it, so a rename — or an alias change — would silently strand the entry.
	var lastAddress: String?
	// What the last script run achieved, in the script's own vocabulary (plain strings,
	// the reverseState lesson: a newer daemon's value round-trips through this one).
	var lastRunStatus: String?
	var lastRunNote: String?
	var lastTransport: String?       // how the guest reached the payload
	var scriptVersion: Int?
	// sshfs in the guest: the capability behind mounting host folders without virtiofs.
	var sshfsAvailable: Bool?
	var sshfsMountReady: Bool?
	var sshfsMountRoot: String?

	var reverseStateValue: SSHInfo.ReverseState {
		guard let reverseState else { return .none }
		return SSHInfo.ReverseState(rawValue: reverseState) ?? .unknown
	}

	// THE list of what must not survive onto a machine with a fresh identity (vm.copy,
	// safeSave promotion): the alias (one VM's name — the setSSH uniqueness check never saw
	// the copy), the lease and pinned host key (publishing them would alias the new VM to
	// the SOURCE), the reverse pair (its authorized_keys line is labeled with the source's
	// marker, so revoking here would remove nothing), and the cached marker itself
	// (re-derived from the fresh identity at the next payload assembly). Disk-derived facts
	// — user, OS, sshfs, what the last script run achieved — stay: they describe the cloned
	// disk. The user's integration switch stays too: it is a choice, not an observation.
	mutating func resetInstanceIdentity() {
		alias = nil
		lastAddress = nil
		guestHostname = nil
		guestHostKey = nil
		reversePublicKey = nil
		reverseState = nil
		marker = nil
	}

	init() {}

	private enum CodingKeys: String, CodingKey {
		case guestUser
		case guestHostname
		case guestOS
		case guestOSVersion
		case guestHostKey
		case reversePublicKey
		case reverseState
		case integrationEnabled
		case lastReportAt
		case marker
		case alias
		case lastAddress
		case lastRunStatus
		case lastRunNote
		case lastTransport
		case scriptVersion
		case sshfsAvailable
		case sshfsMountReady
		case sshfsMountRoot
	}

	// Tolerant decode: every field optional-or-defaulted so future additions round-trip.
	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.guestUser = try c.decodeIfPresent(String.self, forKey: .guestUser)
		self.guestHostname = try c.decodeIfPresent(String.self, forKey: .guestHostname)
		self.guestOS = try c.decodeIfPresent(String.self, forKey: .guestOS)
		self.guestOSVersion = try c.decodeIfPresent(String.self, forKey: .guestOSVersion)
		self.guestHostKey = try c.decodeIfPresent(String.self, forKey: .guestHostKey)
		self.reversePublicKey = try c.decodeIfPresent(String.self, forKey: .reversePublicKey)
		self.reverseState = try c.decodeIfPresent(String.self, forKey: .reverseState)
		self.integrationEnabled =
			try c.decodeIfPresent(Bool.self, forKey: .integrationEnabled) ?? false
		self.lastReportAt = try c.decodeIfPresent(Date.self, forKey: .lastReportAt)
		self.marker = try c.decodeIfPresent(String.self, forKey: .marker)
		self.alias = try c.decodeIfPresent(String.self, forKey: .alias)
		self.lastAddress = try c.decodeIfPresent(String.self, forKey: .lastAddress)
		self.lastRunStatus = try c.decodeIfPresent(String.self, forKey: .lastRunStatus)
		self.lastRunNote = try c.decodeIfPresent(String.self, forKey: .lastRunNote)
		self.lastTransport = try c.decodeIfPresent(String.self, forKey: .lastTransport)
		self.scriptVersion = try c.decodeIfPresent(Int.self, forKey: .scriptVersion)
		self.sshfsAvailable = try c.decodeIfPresent(Bool.self, forKey: .sshfsAvailable)
		self.sshfsMountReady = try c.decodeIfPresent(Bool.self, forKey: .sshfsMountReady)
		self.sshfsMountRoot = try c.decodeIfPresent(String.self, forKey: .sshfsMountRoot)
	}
}

extension VMConfig {
	// The alias rules, in one place. An ssh_config Host pattern, so glob characters would
	// silently capture unrelated hosts — and a name with a slash or a space is not a host
	// at all. Uniqueness across VMs is the daemon's check (only it sees every VM).
	static func validateSSHAlias(_ alias: String) throws {
		guard alias.count <= 64 else {
			throw MachmanError(
				code: .invalidArgument, message: "an SSH alias can be at most 64 characters")
		}
		let allowed = CharacterSet(charactersIn:
			"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
		guard alias.unicodeScalars.allSatisfy({ allowed.contains($0) }),
			let first = alias.first, first.isLetter || first.isNumber else {
			throw MachmanError(
				code: .invalidArgument,
				message: "an SSH alias must start with a letter or digit and use only "
					+ "letters, digits, dots, dashes and underscores")
		}
	}

	// vm.ssh.set — nil fields leave that half unchanged. Approving reverse access requires
	// a reported key (there is nothing to install otherwise); an empty alias resets it.
	func setSSH(integrationEnabled: Bool?, reverseApproved: Bool?, alias: String?) throws {
		var state = ssh ?? SSHConfig()
		if let integrationEnabled {
			state.integrationEnabled = integrationEnabled
		}
		if let alias {
			let trimmed = alias.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty {
				state.alias = nil          // back to "<vm>.machman"
			} else {
				try Self.validateSSHAlias(trimmed)
				state.alias = trimmed
			}
		}
		if let reverseApproved {
			if reverseApproved {
				guard state.reversePublicKey != nil else {
					throw MachmanError(
						code: .invalidState,
						message: "no reverse key reported yet — run the SSH Setup script "
							+ "in \(name) with --two-way first")
				}
				state.reverseState = SSHInfo.ReverseState.approved.rawValue
			} else {
				// Answering no is an ANSWER, not a return to the question: a denied key
				// stops being asked about until the guest reports a different one (which
				// SSHReport.apply moves back to pending). Revoking lands here too — same
				// end state, since both mean "this key does not get in".
				state.reverseState = state.reversePublicKey == nil
					? SSHInfo.ReverseState.none.rawValue
					: SSHInfo.ReverseState.denied.rawValue
			}
		}
		let aliasChanged = ssh?.alias != state.alias
		ssh = state
		try saveVMConfig()
		// The pin is keyed by the alias (HostKeyAlias), so renaming without rewriting it
		// would leave sessions verifying against a name that is no longer in the file.
		if aliasChanged {
			SSHSetupInstaller.writeKnownHosts(for: self)
		}
	}

	// The name this VM answers to in ~/.ssh — its own if it has one, the default otherwise.
	var effectiveSSHAlias: String {
		ssh?.alias ?? SSHHostConfigWriter.defaultAlias(for: name)
	}

	// vm.ssh.reset — forget everything SSH this side of the guest: persisted state, the
	// per-VM keypair, and both share dirs (they regenerate at the next assembly while the
	// device stays attached).
	func resetSSH() throws {
		ssh = nil
		try? FileManager.default.removeItem(atPath: configFilePath(file: "ssh"))
		GuestSetupInstaller.removePayload(for: self)
		try saveVMConfig()
	}
}
