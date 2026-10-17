//
//  DropClassifyTests.swift
//  MachmanDesktopCoreTests
//
//  P45: P11 moved the hover verdict and the pasteboard watch's judging off the main thread,
//  but the drop on the tree's background and every paste still asked each file whether it is
//  a folder on the main actor — a file on a sleeping network volume froze the window at the
//  drop or paste the fix was meant to protect. Both classify off the main thread now, then
//  route on it.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Where each folder check ran.
private final class ClassifyLog: @unchecked Sendable {
	private let lock = NSLock()
	private var all = 0
	private var main = 0

	var calls: Int { lock.withLock { all } }
	var onMain: Int { lock.withLock { main } }

	func isDirectory(_ url: URL) -> Bool {
		lock.withLock {
			all += 1
			if pthread_main_np() != 0 { main += 1 }
		}
		return url.hasDirectoryPath
	}
}

// L1: view model on StubMachman.
@MainActor
struct DropClassifyTests {
	private let files = [
		URL(fileURLWithPath: "/Users/demo/shared", isDirectory: true),
		URL(fileURLWithPath: "/Users/demo/x.iso"),
	]

	@Test("P45: a section paste classifies its files off the main thread")
	func aSectionPasteStatsOffMain() async {
		let h = await DesktopHarness.make([Samples.linux("Debian")])
		let log = ClassifyLog()
		AddFlows.paste(
			into: .mounts, entities: [], fileURLs: files, vm: "Debian", viewModel: h.viewModel,
			isDirectory: { log.isDirectory($0) })
		#expect(await eventually {
			h.stub.vms["Debian"]?.mounts.contains { $0.tag == "shared" } == true
		})
		#expect(log.calls > 0)
		#expect(log.onMain == 0)
	}

	@Test("P45: a drop on the tree classifies its files off the main thread")
	func aTreeDropStatsOffMain() async {
		let h = await DesktopHarness.make([Samples.linux("Debian")])
		let log = ClassifyLog()
		#expect(AddFlows.handleFileURLs(
			files, viewModel: h.viewModel, vm: "Debian", isDirectory: { log.isDirectory($0) }))
		#expect(await eventually { h.viewModel.pendingDiskAdd?.urls == [files[1]] })
		#expect(await eventually {
			h.stub.vms["Debian"]?.mounts.contains { $0.tag == "shared" } == true
		})
		#expect(log.calls == 2)
		#expect(log.onMain == 0)
	}
}
