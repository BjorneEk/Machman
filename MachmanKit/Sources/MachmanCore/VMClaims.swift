//
//  VMClaims.swift
//  MachmanCore
//
//  What holds a VM's files in the daemon besides the host serving it (PR14): a start in
//  flight and Save as New VM taking a name. The router's guards read this one table, so a
//  booting VM is visible to every one of them before anything is hosted.
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

		// An exclusive claim holds the VM alone.
		var isExclusive: Bool { true }
	}

	struct Claim {
		let kind: Kind
		// When it was claimed: among starts, the earlier one wins a MAC (checkMACConflict).
		let order: Int
		// The MAC a start boots with.
		let mac: String?
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
	func claim(_ name: String, _ kind: Kind, mac: String? = nil) throws -> Token {
		if let held = table[name]?.first, held.kind.isExclusive || kind.isExclusive {
			throw Self.refusal(name, held.kind)
		}
		return insert(name, kind, mac: mac)
	}

	// The claim without the check: start() checks first, and tests stage a start in flight.
	@discardableResult
	func insert(_ name: String, _ kind: Kind, mac: String? = nil) -> Token {
		let order = nextOrder
		nextOrder += 1
		table[name, default: []].append(Claim(kind: kind, order: order, mac: mac))
		return Token(name: name, order: order)
	}

	func release(_ token: Token) {
		table[token.name]?.removeAll { $0.order == token.order }
		if table[token.name]?.isEmpty == true { table[token.name] = nil }
	}

	func claims(on name: String) -> [Claim] {
		table[name] ?? []
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
		MachmanError(code: .invalidState, message: "\(name) is already starting")
	}
}
