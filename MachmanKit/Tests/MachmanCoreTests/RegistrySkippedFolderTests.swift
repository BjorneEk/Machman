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
}
