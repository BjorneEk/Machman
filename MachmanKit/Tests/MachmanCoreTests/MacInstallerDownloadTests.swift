//
//  MacInstallerDownloadTests.swift
//  MachmanCoreTests
//
//  D33: macOS installs run in Machman Agent, on its main actor. The downloaded restore image's
//  last move into the VM folder ran there too — with the library on another volume a ~13 GB
//  copy, during which the agent answered no client for minutes. URLSession serves a file:// URL
//  like any download, so the real download path runs here with a fake last move.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

// Whether the main actor ran while a move waited for it.
private final class MainActorProbe: @unchecked Sendable {
	private let ran = DispatchSemaphore(value: 0)

	func signal() {
		ran.signal()
	}

	func waitForMain() -> Bool {
		ran.wait(timeout: .now() + 30) == .success
	}
}

private struct MainActorBlocked: Error {}

struct MacInstallerDownloadTests {
	@Test("D33: the downloaded restore image moves into the VM folder off the main actor")
	@MainActor func theLastMoveRunsOffTheMainActor() async throws {
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"mac","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		let dir = TestEnvironment.scratch + "d33-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let served = URL(fileURLWithPath: dir + "/served.ipsw")
		try Data("restore image".utf8).write(to: served)
		let local = URL(fileURLWithPath: dir + "/" + MacInstaller.restoreImageFileName)

		let installer = MacInstaller(config: config)
		let probe = MainActorProbe()
		installer.placeDownload = { holding, local in
			// The main actor must run while the move is in flight. A move on the main actor
			// can't let it, and the wait ends at its deadline instead of hanging the test.
			Task { @MainActor in probe.signal() }
			let mainRan = probe.waitForMain()
			try FileManager.default.moveItem(at: holding, to: local)
			if !mainRan { throw MainActorBlocked() }
		}
		try await installer.download(from: served, to: local)
		#expect(try Data(contentsOf: local) == Data("restore image".utf8))
	}
}
