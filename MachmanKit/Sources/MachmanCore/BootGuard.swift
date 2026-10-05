//
//  BootGuard.swift
//  MachmanCore
//
//  The one cross-VM boot guard (PR15): no VM boots with a MAC another running or starting VM
//  uses (one of them would lose networking), and none attaches a writable disk file another
//  one has attached (C5: two writers corrupt it). Pure over what the caller knows of the
//  others, so the router's start and every other boot path ask the same question.
//

import Foundation
import MachmanAPI

enum BootGuard {
	// The VM about to boot. `order`: its start claim's, when it has one — among starts, the
	// earlier claim wins a MAC, so two same-MAC starts never both fail.
	struct Candidate {
		let name: String
		var mac: String?
		var disks: Set<String> = []
		var order: Int?
	}

	// Another VM that runs or is starting, and what it holds.
	struct Other {
		enum Role: Equatable {
			case running
			case starting(order: Int)
		}

		let name: String
		let role: Role
		let mac: String?
		// The writable disk files it has attached for sure, and the ones it may have: an entry
		// whose flag can't tell (a host's disabled entry it may have started with).
		var attached: Set<String> = []
		var mayHaveAttached: Set<String> = []
	}

	// `force` overrides it: lost networking recovers.
	static func checkMAC(_ candidate: Candidate, among others: [Other]) throws {
		guard let mac = candidate.mac else { return }
		let name = candidate.name
		let mine = candidate.order ?? Int.max
		let sharers = others.filter { $0.name != name && $0.mac == mac }
		if let running = sharers.first(where: { $0.role == .running }) {
			throw MachmanError(
				code: .macConflict,
				message: "\(name) and the running VM \u{201C}\(running.name)\u{201D} "
					+ "share MAC address \(mac), so one of them would lose networking")
		}
		let earlier = sharers.compactMap { other -> (Other, Int)? in
			guard case .starting(let order) = other.role, order < mine else { return nil }
			return (other, order)
		}.min { $0.1 < $1.1 }?.0
		if let earlier {
			throw MachmanError(
				code: .macConflict,
				message: "\(name) and \u{201C}\(earlier.name)\u{201D}, which is starting, share "
					+ "MAC address \(mac), so one of them would lose networking")
		}
	}

	// Never overridden: a disk written by two VMs does not recover. Isos attach read-only and
	// never count. The first sharer by name, and its first shared file by path.
	static func checkDisks(_ candidate: Candidate, among others: [Other]) throws {
		guard !candidate.disks.isEmpty else { return }
		let name = candidate.name
		for other in others.sorted(by: { $0.name < $1.name }) where other.name != name {
			let theirs = other.attached.union(other.mayHaveAttached)
			guard let file = candidate.disks.intersection(theirs).sorted().first else { continue }
			let disk = (file as NSString).lastPathComponent
			throw MachmanError(
				code: .invalidState,
				message: (other.attached.contains(file)
					? "\(other.name) is running with \(disk) attached"
					: "\(other.name) may still have \(disk) attached")
					+ " — stop \(other.name) before starting \(name)")
		}
	}
}
