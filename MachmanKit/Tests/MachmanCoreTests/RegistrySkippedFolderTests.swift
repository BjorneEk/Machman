//
//  RegistrySkippedFolderTests.swift
//  MachmanCoreTests
//
//  D38: a VM folder whose config doesn't read vanished from every client with one log line —
//  its name even looked free. The registry now tells every client, including the ones that
//  connect after its scan, and says the same when a known VM's config stops reading.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

// Every warning a stream carries, in order.
@MainActor
private final class WarningTap {
	private(set) var warnings: [(vm: String?, message: String)] = []
	private var reader: Task<Void, Never>?

	init(_ stream: AsyncStream<VMEvent>) {
		reader = Task { @MainActor [weak self] in
			for await event in stream {
				if case .log(let vm, .warning, let message) = event {
					self?.warnings.append((vm, message))
				}
			}
		}
	}

	init(_ stream: AsyncStream<EventLine>) {
		reader = Task { @MainActor [weak self] in
			for await line in stream {
				if case .log(let vm, .warning, let message) = line.event {
					self?.warnings.append((vm, message))
				}
			}
		}
	}

	func stop() {
		reader?.cancel()
	}
}

@MainActor
struct RegistrySkippedFolderTests {
	private func write(_ text: String, as name: String) throws {
		let dir = "\(machmanVMDir)/\(name)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		try Data(text.utf8).write(to: URL(fileURLWithPath: "\(dir)/config"))
	}

	@Test("D38: a VM folder whose settings can't be read reaches every client as a warning")
	func anUnreadableFolderIsAnnounced() async throws {
		let (events, lines, later) = try VMTestDir.withRedirectedDir {
			try write("{\"name\":", as: "broken")
			try FileManager.default.createDirectory(
				atPath: "\(machmanVMDir)/not a VM", withIntermediateDirectories: true)
			try VMConfig.createNewVMDirectory(name: "fine")
			_ = try VMConfig(name: "fine", memorySize: 1 << 30, cpuCount: 2)
			// Clients subscribe after the scan, as every client of a daemon does.
			let registry = VMRegistry()
			#expect(registry.vm(named: "broken") == nil)
			#expect(registry.vm(named: "fine") != nil)
			let events = WarningTap(registry.events.stream())
			let lines = WarningTap(registry.events.lineStream())
			// A known VM whose config stops reading (after its vmhost exits) leaves the list
			// with the same words to the clients already there.
			try write("[", as: "fine")
			registry.reload(name: "fine")
			#expect(registry.vm(named: "fine") == nil)
			let later = WarningTap(registry.events.stream())
			return (events, lines, later)
		}
		defer { [events, lines, later].forEach { $0.stop() } }
		let said = VMRegistry.unreadableWarning
		#expect(await eventually { events.warnings.count == 2 })
		#expect(events.warnings.map(\.vm) == ["broken", "fine"])
		#expect(events.warnings.allSatisfy { $0.message == said })
		#expect(await eventually { lines.warnings.count == 2 })
		#expect(lines.warnings.map(\.vm) == ["broken", "fine"])
		// One that subscribes after both hears both, once each; a folder without a config
		// is no VM and is never announced.
		#expect(await eventually { later.warnings.count == 2 })
		#expect(later.warnings.map(\.vm) == ["broken", "fine"])
	}

	// D38 (review 4, from the wave's review): the warning reached every client that connected
	// later even once the folder was gone or its settings read again — a VM listed again under
	// the name heard that it isn't in the list. It now stands only while it holds.
	@Test("D38: the warning stops once the folder is gone or its settings read again")
	func theWarningStopsWhenItNoLongerHolds() async throws {
		let readable = #"{"memorySize":1073741824,"cpuCount":2,"created":1000}"#
		let (before, after) = try VMTestDir.withRedirectedDir {
			try write("[", as: "fixed")
			try write("[", as: "deleted")
			try VMConfig.createNewVMDirectory(name: "relisted")
			_ = try VMConfig(name: "relisted", memorySize: 1 << 30, cpuCount: 2)
			let registry = VMRegistry()
			try write("[", as: "relisted")
			registry.reload(name: "relisted")
			let before = WarningTap(registry.events.stream())
			// Fixed by hand, deleted, and deleted then made again as a VM the list takes.
			try write(readable, as: "fixed")
			try FileManager.default.removeItem(atPath: "\(machmanVMDir)/deleted")
			try FileManager.default.removeItem(atPath: "\(machmanVMDir)/relisted")
			try VMConfig.createNewVMDirectory(name: "relisted")
			_ = try VMConfig(name: "relisted", memorySize: 1 << 30, cpuCount: 2)
			_ = try registry.adoptFromDisk(name: "relisted")
			let after = WarningTap(registry.events.stream())
			// What both streams hear last, so a missing notice is seen missing, not awaited.
			registry.events.emit(.log(vm: nil, level: .warning, message: "marker"))
			return (before, after)
		}
		defer { [before, after].forEach { $0.stop() } }
		#expect(await eventually { before.warnings.contains { $0.message == "marker" } })
		#expect(Set(before.warnings.compactMap(\.vm)) == ["fixed", "deleted", "relisted"])
		#expect(await eventually { after.warnings.contains { $0.message == "marker" } })
		#expect(after.warnings.map(\.message) == ["marker"], "\(after.warnings)")
	}

	// D38 (review 4, from the wave's final pass): the registry scans only at startup, so a
	// folder whose settings the user fixed stayed out of the list until the agent restarted —
	// and its warning stopped, so nothing said why. The next client to connect finds it listed.
	@Test("D38: a folder whose settings are fixed is listed when the next client connects")
	func aFixedFolderIsListedAtTheNextConnect() async throws {
		let readable = #"{"memorySize":1073741824,"cpuCount":2,"created":1000}"#
		let (after, listedBefore, listedAfter) = try VMTestDir.withRedirectedDir {
			try write("[", as: "fixed")
			let registry = VMRegistry()
			try write(readable, as: "fixed")
			let listedBefore = registry.vm(named: "fixed") != nil
			let after = WarningTap(registry.events.stream())
			let listedAfter = registry.vm(named: "fixed") != nil
			registry.events.emit(.log(vm: nil, level: .warning, message: "marker"))
			return (after, listedBefore, listedAfter)
		}
		defer { after.stop() }
		#expect(!listedBefore)
		#expect(listedAfter)
		#expect(await eventually { after.warnings.contains { $0.message == "marker" } })
		#expect(after.warnings.map(\.message) == ["marker"], "\(after.warnings)")
	}
}
