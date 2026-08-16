//
//  SSHInfo.swift
//  MachmanAPI
//
//  Per-VM SSH state as served over the API (wire 1.0.6). Three halves in one flat shape:
//  persisted facts from the guest's install report (owned by whichever process owns the
//  config), server-resolved paths and names clients must never derive themselves (the
//  DiskInfo.path rule), and the daemon-overlay half — live address and reachability
//  (safeRun pattern; the vmhost always serves those nil). Flat optionals so non-Swift
//  clients see obvious JSON.
//

import Foundation

public struct SSHInfo: Codable, Sendable, Equatable {
	// Guest→host access: none (never offered), pending (the guest reported a reverse key
	// and is waiting on an answer), approved (key installed in the host's
	// authorized_keys), denied (answered no — the key stays on file, nothing is installed,
	// and the UI stops asking until the guest reports a DIFFERENT key).
	public enum ReverseState: String, Codable, Sendable, Equatable {
		case none
		case pending
		case approved
		case denied
		case unknown   // decode fallback only; never encode it

		public init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			self = ReverseState(rawValue: raw) ?? .unknown
		}
	}

	// Whether the guest's sshd actually answers (1.0.6): unknown (not probed — SSH was
	// never set up here, or the VM is stopped), waiting (probing since the VM came up),
	// ready (a connection succeeded), unreachable (gave up; reachabilityDetail says why).
	// Daemon-only, never persisted: it describes this run, not the VM.
	public enum Reachability: String, Codable, Sendable, Equatable {
		case unknown
		case waiting
		case ready
		case unreachable

		public init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			self = Reachability(rawValue: raw) ?? .unknown
		}
	}

	// Persisted half — from the guest's install report.
	public var guestUser: String?
	public var guestHostname: String?
	public var guestOS: String?       // /etc/os-release ID, "darwin", or "freebsd"
	public var guestOSVersion: String?
	// The guest's SSH host public key line — what the daemon pins into known_hosts
	// (host keys are public by nature).
	public var guestHostKey: String?
	public var reverseState: ReverseState
	public var reversePublicKey: String?   // guest's reverse key — public half only
	public var integrationEnabled: Bool?   // managed ~/.ssh entry on/off
	public var lastReportAt: Date?         // stamped by the HOST at ingestion
	// What the last script run achieved: "ok" | "partial" | "failed" (a plain string —
	// a value written by a NEWER daemon must survive this one's round trip), with one
	// sentence of detail, and how the guest reached the payload ("virtiofs" | "sshfs" |
	// "local"). scriptVersion is the version of the script that produced the report.
	public var lastRunStatus: String?
	public var lastRunNote: String?
	public var lastTransport: String?
	public var scriptVersion: Int?
	// sshfs in the guest (1.0.6): the capability that lets a guest without a virtiofs
	// driver mount host folders over the guest→host SSH link. Usable only once
	// reverseState is .approved — clients compute that rather than trusting a stale flag.
	public var sshfsAvailable: Bool?
	public var sshfsMountReady: Bool?      // fuse loadable/persisted and mounts permitted
	public var sshfsMountRoot: String?     // where the guest would mount host folders
	// Server-resolved half — absolute paths and names clients must not derive.
	public var alias: String?              // effective ~/.ssh alias ("<vm>.machman" by default)
	public var identityFilePath: String?   // per-VM private key; nil until it exists
	public var knownHostsPath: String?     // per-VM pinned host keys; nil until the key exists
	public var setupSharePath: String?     // the directory a driverless guest sshfs-mounts
	public var hostUser: String?           // the Mac account Machman runs as
	// Daemon-overlay half — present only while the VM runs.
	public var address: String?
	public var addressSource: String?      // "dhcp" | "arp"
	public var hostAddressForGuest: String?   // this Mac as the guest addresses it (gateway)
	public var reachability: Reachability?
	public var reachabilityDetail: String?
	public var readySince: Date?

	public init(
		guestUser: String? = nil, guestHostname: String? = nil, guestOS: String? = nil,
		guestOSVersion: String? = nil, guestHostKey: String? = nil,
		reverseState: ReverseState = .none, reversePublicKey: String? = nil,
		integrationEnabled: Bool? = nil, lastReportAt: Date? = nil,
		lastRunStatus: String? = nil, lastRunNote: String? = nil,
		lastTransport: String? = nil, scriptVersion: Int? = nil,
		sshfsAvailable: Bool? = nil, sshfsMountReady: Bool? = nil,
		sshfsMountRoot: String? = nil,
		alias: String? = nil, identityFilePath: String? = nil,
		knownHostsPath: String? = nil, setupSharePath: String? = nil, hostUser: String? = nil,
		address: String? = nil, addressSource: String? = nil,
		hostAddressForGuest: String? = nil,
		reachability: Reachability? = nil, reachabilityDetail: String? = nil,
		readySince: Date? = nil
	) {
		self.guestUser = guestUser
		self.guestHostname = guestHostname
		self.guestOS = guestOS
		self.guestOSVersion = guestOSVersion
		self.guestHostKey = guestHostKey
		self.reverseState = reverseState
		self.reversePublicKey = reversePublicKey
		self.integrationEnabled = integrationEnabled
		self.lastReportAt = lastReportAt
		self.lastRunStatus = lastRunStatus
		self.lastRunNote = lastRunNote
		self.lastTransport = lastTransport
		self.scriptVersion = scriptVersion
		self.sshfsAvailable = sshfsAvailable
		self.sshfsMountReady = sshfsMountReady
		self.sshfsMountRoot = sshfsMountRoot
		self.alias = alias
		self.identityFilePath = identityFilePath
		self.knownHostsPath = knownHostsPath
		self.setupSharePath = setupSharePath
		self.hostUser = hostUser
		self.address = address
		self.addressSource = addressSource
		self.hostAddressForGuest = hostAddressForGuest
		self.reachability = reachability
		self.reachabilityDetail = reachabilityDetail
		self.readySince = readySince
	}

	// Tolerant decode; encode stays synthesized so nil optionals are omitted.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.guestUser = try c.decodeIfPresent(String.self, forKey: .guestUser)
		self.guestHostname = try c.decodeIfPresent(String.self, forKey: .guestHostname)
		self.guestOS = try c.decodeIfPresent(String.self, forKey: .guestOS)
		self.guestOSVersion = try c.decodeIfPresent(String.self, forKey: .guestOSVersion)
		self.guestHostKey = try c.decodeIfPresent(String.self, forKey: .guestHostKey)
		self.reverseState =
			try c.decodeIfPresent(ReverseState.self, forKey: .reverseState) ?? .none
		self.reversePublicKey = try c.decodeIfPresent(String.self, forKey: .reversePublicKey)
		self.integrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .integrationEnabled)
		self.lastReportAt = try c.decodeIfPresent(Date.self, forKey: .lastReportAt)
		self.lastRunStatus = try c.decodeIfPresent(String.self, forKey: .lastRunStatus)
		self.lastRunNote = try c.decodeIfPresent(String.self, forKey: .lastRunNote)
		self.lastTransport = try c.decodeIfPresent(String.self, forKey: .lastTransport)
		self.scriptVersion = try c.decodeIfPresent(Int.self, forKey: .scriptVersion)
		self.sshfsAvailable = try c.decodeIfPresent(Bool.self, forKey: .sshfsAvailable)
		self.sshfsMountReady = try c.decodeIfPresent(Bool.self, forKey: .sshfsMountReady)
		self.sshfsMountRoot = try c.decodeIfPresent(String.self, forKey: .sshfsMountRoot)
		self.alias = try c.decodeIfPresent(String.self, forKey: .alias)
		self.identityFilePath = try c.decodeIfPresent(String.self, forKey: .identityFilePath)
		self.knownHostsPath = try c.decodeIfPresent(String.self, forKey: .knownHostsPath)
		self.setupSharePath = try c.decodeIfPresent(String.self, forKey: .setupSharePath)
		self.hostUser = try c.decodeIfPresent(String.self, forKey: .hostUser)
		self.address = try c.decodeIfPresent(String.self, forKey: .address)
		self.addressSource = try c.decodeIfPresent(String.self, forKey: .addressSource)
		self.hostAddressForGuest =
			try c.decodeIfPresent(String.self, forKey: .hostAddressForGuest)
		self.reachability = try c.decodeIfPresent(Reachability.self, forKey: .reachability)
		self.reachabilityDetail =
			try c.decodeIfPresent(String.self, forKey: .reachabilityDetail)
		self.readySince = try c.decodeIfPresent(Date.self, forKey: .readySince)
	}
}
