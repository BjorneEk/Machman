//
//  BootGuard.swift
//  MachmanCore
//
//  The one cross-VM boot guard (PR15): no VM boots with a MAC another running or starting VM
//  uses (one of them would lose networking), and none attaches a writable disk file another
//  one has attached (C5: two writers corrupt it). Pure over what the caller knows of the
//  others, so the router's start and every other boot path ask the same question — Start
//  at login among them (E38), read from the configs on disk.
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
			// It starts at login, as the candidate is about to (C8).
			case autostart
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
		if let atLogin = sharers.first(where: { $0.role == .autostart }) {
			throw MachmanError(
				code: .invalidState,
				message: "\(atLogin.name) also starts at login with MAC address \(mac) — "
					+ "regenerate the MAC address of one of them")
		}
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
			if other.role == .autostart {
				throw MachmanError(
					code: .invalidState,
					message: "\(other.name) also starts at login with \(disk) attached — turn "
						+ "off Start at login for one of them")
			}
			throw MachmanError(
				code: .invalidState,
				message: (other.attached.contains(file)
					? "\(other.name) is running with \(disk) attached"
					: "\(other.name) may still have \(disk) attached")
					+ " — stop \(other.name) before starting \(name)")
		}
	}

	// MARK: - Configs on disk

	// A VM's config as its file says now, decoded only: never migrated or saved, since
	// another process may own it (a vmhost saves its VM's config whole). nil when unreadable.
	// Its paths resolve through machmanVMDir, which every caller has pointed at `library`.
	static func peekConfig(name: String, library: String) -> VMConfig? {
		guard let data = FileManager.default.contents(atPath: library + "/" + name + "/config"),
			let config = try? JSONDecoder().decode(VMConfig.self, from: data) else { return nil }
		config.name = name   // the directory name is authoritative (VMConfig.load)
		return config
	}

	// Every VM folder in the library whose config reads.
	static func libraryConfigs(_ library: String) -> [VMConfig] {
		let entries = (try? FileManager.default.contentsOfDirectory(atPath: library)) ?? []
		return entries.filter { !$0.hasPrefix(".") }.sorted()
			.compactMap { peekConfig(name: $0, library: library) }
	}

	// C8: turning Start at login on beside another VM that starts at login and shares a
	// writable disk file or the MAC — at the next login both would boot. A VM that already
	// starts at login is let be, so its other run defaults stay editable.
	static func autostartConflict(turningOn name: String, library: String) -> MachmanError? {
		guard let mine = peekConfig(name: name, library: library),
			!mine.startPolicy.autostart else { return nil }
		let others = libraryConfigs(library)
			.filter { $0.name != name && $0.startPolicy.autostart }
			.map {
				Other(
					name: $0.name, role: .autostart, mac: $0.macAddress,
					attached: $0.writableDiskFiles)
			}
		do {
			try checkDisks(Candidate(name: name, disks: mine.writableDiskFiles), among: others)
			try checkMAC(Candidate(name: name, mac: mine.macAddress), among: others)
		} catch let error as MachmanError {
			return error
		} catch {
			return nil
		}
		return nil
	}
}
