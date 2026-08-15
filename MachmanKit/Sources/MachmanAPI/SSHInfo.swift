//
//  SSHInfo.swift
//  MachmanAPI
//
//  Per-VM SSH state as served over the API (wire 1.0.5). Two halves in one flat shape:
//  persisted facts from the guest's install report (owned by whichever process owns the
//  config), and the daemon-overlay address (live discovery, safeRun pattern — the vmhost
//  always serves those nil). Flat optionals so non-Swift clients see obvious JSON.
//

import Foundation

public struct SSHInfo: Codable, Sendable, Equatable {
	// Guest→host access: none (never offered), pending (the guest reported a reverse key,
	// awaiting user approval), approved (key installed in the host's authorized_keys).
	public enum ReverseState: String, Codable, Sendable, Equatable {
		case none
		case pending
		case approved
		case unknown   // decode fallback only; never encode it

		public init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			self = ReverseState(rawValue: raw) ?? .unknown
		}
	}

	// Persisted half — from the guest's install report.
	public var guestUser: String?
	public var guestHostname: String?
	public var guestOS: String?       // /etc/os-release ID, "darwin", or "freebsd"
	public var reverseState: ReverseState
	public var reversePublicKey: String?   // guest's reverse key — public half only
	public var integrationEnabled: Bool?   // managed ~/.ssh entry on/off
	public var lastReportAt: Date?         // stamped by the HOST at ingestion
	// Daemon-overlay half — present only while the VM runs and discovery has an answer.
	public var address: String?
	public var addressSource: String?      // "dhcp" | "arp"
	// Server-resolved absolute path of the per-VM private key (DiskInfo.path precedent:
	// clients must not derive library paths). nil until the key exists.
	public var identityFilePath: String?

	public init(
		guestUser: String? = nil, guestHostname: String? = nil, guestOS: String? = nil,
		reverseState: ReverseState = .none, reversePublicKey: String? = nil,
		integrationEnabled: Bool? = nil, lastReportAt: Date? = nil,
		address: String? = nil, addressSource: String? = nil,
		identityFilePath: String? = nil
	) {
		self.guestUser = guestUser
		self.guestHostname = guestHostname
		self.guestOS = guestOS
		self.reverseState = reverseState
		self.reversePublicKey = reversePublicKey
		self.integrationEnabled = integrationEnabled
		self.lastReportAt = lastReportAt
		self.address = address
		self.addressSource = addressSource
		self.identityFilePath = identityFilePath
	}

	// Tolerant decode; encode stays synthesized so nil optionals are omitted.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.guestUser = try c.decodeIfPresent(String.self, forKey: .guestUser)
		self.guestHostname = try c.decodeIfPresent(String.self, forKey: .guestHostname)
		self.guestOS = try c.decodeIfPresent(String.self, forKey: .guestOS)
		self.reverseState =
			try c.decodeIfPresent(ReverseState.self, forKey: .reverseState) ?? .none
		self.reversePublicKey = try c.decodeIfPresent(String.self, forKey: .reversePublicKey)
		self.integrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .integrationEnabled)
		self.lastReportAt = try c.decodeIfPresent(Date.self, forKey: .lastReportAt)
		self.address = try c.decodeIfPresent(String.self, forKey: .address)
		self.addressSource = try c.decodeIfPresent(String.self, forKey: .addressSource)
		self.identityFilePath = try c.decodeIfPresent(String.self, forKey: .identityFilePath)
	}
}
