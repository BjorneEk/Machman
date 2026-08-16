//
//  SSHConfig.swift
//  MachmanCore
//
//  Persisted SSH state (wire 1.0.5): what the guest's install report taught us plus the
//  user's per-VM switches. Absent from disk until SSH is first used (conditional encode) —
//  and the reason 1.0.5 is the version floor: an older daemon's config rewrite drops the
//  unknown key.
//

import Foundation
import MachmanAPI

struct SSHConfig: Codable, Equatable {
	var guestUser: String?
	var guestHostname: String?
	var guestOS: String?
	var guestHostKey: String?        // "ssh-ed25519 AAAA…" line from the guest's report
	var reversePublicKey: String?    // guest's reverse key — public half only
	// Plain string on disk (the GuestDevice.kind lesson): a value written by a NEWER daemon
	// survives this daemon's load/save cycle verbatim.
	var reverseState: String?
	var integrationEnabled: Bool = false
	var lastReportAt: Date?          // stamped by the host at ingestion
	var marker: String?              // labels guest/host artifacts; never on the wire

	var reverseStateValue: SSHInfo.ReverseState {
		guard let reverseState else { return .none }
		return SSHInfo.ReverseState(rawValue: reverseState) ?? .unknown
	}

	init() {}

	private enum CodingKeys: String, CodingKey {
		case guestUser
		case guestHostname
		case guestOS
		case guestHostKey
		case reversePublicKey
		case reverseState
		case integrationEnabled
		case lastReportAt
		case marker
	}

	// Tolerant decode: every field optional-or-defaulted so future additions round-trip.
	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.guestUser = try c.decodeIfPresent(String.self, forKey: .guestUser)
		self.guestHostname = try c.decodeIfPresent(String.self, forKey: .guestHostname)
		self.guestOS = try c.decodeIfPresent(String.self, forKey: .guestOS)
		self.guestHostKey = try c.decodeIfPresent(String.self, forKey: .guestHostKey)
		self.reversePublicKey = try c.decodeIfPresent(String.self, forKey: .reversePublicKey)
		self.reverseState = try c.decodeIfPresent(String.self, forKey: .reverseState)
		self.integrationEnabled =
			try c.decodeIfPresent(Bool.self, forKey: .integrationEnabled) ?? false
		self.lastReportAt = try c.decodeIfPresent(Date.self, forKey: .lastReportAt)
		self.marker = try c.decodeIfPresent(String.self, forKey: .marker)
	}
}

extension VMConfig {
	// vm.ssh.set — nil fields leave that half unchanged. Approving reverse access requires
	// a reported key (there is nothing to install otherwise).
	func setSSH(integrationEnabled: Bool?, reverseApproved: Bool?) throws {
		var state = ssh ?? SSHConfig()
		if let integrationEnabled {
			state.integrationEnabled = integrationEnabled
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
				state.reverseState = state.reversePublicKey == nil
					? SSHInfo.ReverseState.none.rawValue
					: SSHInfo.ReverseState.pending.rawValue
			}
		}
		ssh = state
		try saveVMConfig()
	}

	// vm.ssh.reset — forget everything SSH this side of the guest: persisted state, the
	// per-VM keypair, and both share dirs (they regenerate at the next assembly while the
	// device stays attached).
	func resetSSH() throws {
		ssh = nil
		try? FileManager.default.removeItem(atPath: configFilePath(file: "ssh"))
		SSHSetupInstaller.removePayload(for: self)
		try saveVMConfig()
	}
}
