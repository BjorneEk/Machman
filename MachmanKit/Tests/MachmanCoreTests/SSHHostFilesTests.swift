//
//  SSHHostFilesTests.swift
//  MachmanTests
//
//  PR17's owner of every ~/.ssh write, against a temp root (never the real ~/.ssh). C22:
//  every trigger used to start its own regeneration, and the one that FINISHED last won —
//  a slow pass that gathered before a delete, an alias change or a rename landed after the
//  fresh one and restored the old block. One pass runs at a time now, and requests made
//  during it buy exactly one more pass, which gathers the newest state.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

// A one-shot gate a parked source waits on.
@MainActor
private final class Gate {
	private var isOpen = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func open() {
		isOpen = true
		waiters.forEach { $0.resume() }
		waiters = []
	}
}

// What a source saw: how often it ran, and how many ran at once at most.
@MainActor
private final class Passes {
	var version = 1
	var calls = 0
	var running = 0
	var mostAtOnce = 0
}

@MainActor
struct SSHHostFilesTests {
	private func makeRoot() throws -> URL {
		let root = TestEnvironment.scratchURL
			.appendingPathComponent("machman-sshfiles-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private func entry(_ alias: String) -> SSHHostConfigWriter.VMEntry {
		SSHHostConfigWriter.VMEntry(
			name: "dev", alias: alias, user: "admin", address: "192.168.64.9",
			identityFilePath: nil, hostKey: nil)
	}

	private func managed(_ root: URL) -> String {
		(try? String(contentsOf: root.appendingPathComponent("machman/config"), encoding: .utf8))
			?? ""
	}

	@Test func requestsDuringAPassRunOnceMoreOnTheNewestState() async throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let files = SSHHostFiles(writer: SSHHostConfigWriter(sshDir: root))
		let gate = Gate()
		let passes = Passes()
		let source: SSHHostFiles.EntrySource = {
			passes.calls += 1
			passes.running += 1
			passes.mostAtOnce = max(passes.mostAtOnce, passes.running)
			defer { passes.running -= 1 }
			let seen = passes.version
			if passes.calls == 1 { await gate.wait() }   // the slow first pass
			return [self.entry("v\(seen).machman")]
		}

		files.regenerate(from: source)
		#expect(await eventually { passes.calls == 1 })
		passes.version = 2
		files.regenerate(from: source)
		passes.version = 3
		files.regenerate(from: source)
		files.regenerate(from: source)
		gate.open()
		await files.settled()

		#expect(passes.calls == 2)        // three requests during pass 1 cost one more pass
		#expect(passes.mostAtOnce == 1)
		let text = managed(root)
		#expect(text.contains(#"Host "v3.machman""#))
		#expect(!text.contains("v1.machman"))
	}

	@Test func aRequestWithNothingInFlightRunsOnePass() async throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let files = SSHHostFiles(writer: SSHHostConfigWriter(sshDir: root))
		let passes = Passes()

		files.regenerate {
			passes.calls += 1
			return [self.entry("dev.machman")]
		}
		await files.settled()

		#expect(passes.calls == 1)
		#expect(managed(root).contains(#"Host "dev.machman""#))
	}
}
