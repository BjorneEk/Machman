//
//  VMClaims.swift
//  MachmanCore
//
//  What holds a VM's files in the daemon besides the host serving it (PR14): a start in
//  flight, Save as New VM taking a name, and the long copies that write into a VM's folder
//  or read it whole. The router's guards read this one table, so a booting VM is visible to
//  every one of them before anything is hosted, and no copy can be undone by a start or
//  pulled away by a rename, delete or copy while it runs (E33, D20).
//

import Foundation
import MachmanAPI

@MainActor
final class VMClaims {
	enum Kind: Equatable {
		// vm.start, from its first check until the host joined or the start failed.
		case starting
		// Save as New VM's new name, until the vmhost that serves it replied.
		case saving
		// vm.copy reads the whole folder.
		case copying
		// The copies that land a new file in the folder and point the config at it.
		case importingDisk
		case promotingDisk
		case importingKernel

		// An exclusive claim holds the VM alone. The copies that only add files coexist —
		// each names its file as it lands (D18) — but never beside an exclusive one.
		var isExclusive: Bool {
			switch self {
			case .starting, .saving, .copying: return true
			case .importingDisk, .promotingDisk, .importingKernel: return false
			}
		}

		// What the VM is doing, after its name: "alpha is importing a disk".
		var activity: String {
			switch self {
			case .starting, .saving: return "is starting"
			case .copying: return "is being copied"
			case .importingDisk: return "is importing a disk"
			case .promotingDisk: return "is promoting a disk"
			case .importingKernel: return "is importing a kernel file"
			}
		}
	}

	struct Claim {
		let kind: Kind
		// When it was claimed: among starts, the earlier one wins a MAC (checkMACConflict).
		let order: Int
		// The MAC a start boots with.
		let mac: String?
		// Whether the work runs in this process. A copy proxied to the VM's vmhost runs there
		// and outlives this daemon.
		let inDaemon: Bool
	}

	// Names one claim, for its release.
	struct Token: Hashable {
		let name: String
		let order: Int
	}

	private(set) var table: [String: [Claim]] = [:]
	private var nextOrder = 0

	// Claims `name` for `kind`, refused while the VM holds a claim the kind can't share.
	// Main-actor confinement makes the check-then-insert atomic.
	func claim(
		_ name: String, _ kind: Kind, mac: String? = nil, inDaemon: Bool = true
	) throws -> Token {
		if let held = table[name]?.first, held.kind.isExclusive || kind.isExclusive {
			throw Self.refusal(name, held.kind)
		}
		return insert(name, kind, mac: mac, inDaemon: inDaemon)
	}

	// The claim without the check: tests stage a start in flight.
	@discardableResult
	func insert(
		_ name: String, _ kind: Kind, mac: String? = nil, inDaemon: Bool = true
	) -> Token {
		let order = nextOrder
		nextOrder += 1
		table[name, default: []].append(
			Claim(kind: kind, order: order, mac: mac, inDaemon: inDaemon))
		return Token(name: name, order: order)
	}

	func release(_ token: Token) {
		table[token.name]?.removeAll { $0.order == token.order }
		if table[token.name]?.isEmpty == true { table[token.name] = nil }
	}

	func claims(on name: String) -> [Claim] {
		table[name] ?? []
	}

	// Why `name` can't start or change as a whole right now, or nil when nothing holds it.
	func refusal(for name: String) -> MachmanError? {
		table[name]?.first.map { Self.refusal(name, $0.kind) }
	}

	// The names a start or a save holds: the router lists them as starting.
	var startingNames: Set<String> {
		Set(table.filter { $0.value.contains { $0.kind == .starting || $0.kind == .saving } }
			.keys)
	}

	// The MAC each start in flight boots with, and its claim's order.
	var startMACs: [String: (order: Int, mac: String)] {
		var macs: [String: (order: Int, mac: String)] = [:]
		for (name, claims) in table {
			for claim in claims where claim.kind == .starting {
				if let mac = claim.mac { macs[name] = (claim.order, mac) }
			}
		}
		return macs
	}

	static func refusal(_ name: String, _ kind: Kind) -> MachmanError {
		switch kind {
		case .starting, .saving:
			return MachmanError(code: .invalidState, message: "\(name) is already starting")
		case .copying, .importingDisk, .promotingDisk, .importingKernel:
			return MachmanError(
				code: .invalidState,
				message: "\(name) \(kind.activity) — try again when it finishes")
		}
	}
}
