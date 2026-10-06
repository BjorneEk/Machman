//
//  StoreFunnelTests.swift
//  MachmanDesktopCoreTests
//
//  What the view model republishes (P9). It forwarded every change of the operations store
//  and the canvas layouts, so a progress tick twice a second, a divider move or a tab tap
//  re-rendered every view observing it — the whole window. The views that show progress and
//  layouts observe those stores themselves; the view model passes on only what its own
//  answers read: an install's stage (Start, Install and their help wait for it).
//

import Testing
import Foundation
import Combine
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct StoreFunnelTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	@Test("P9: progress ticks and divider moves leave the view model quiet")
	func ticksAndDividersLeaveItQuiet() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		var canvas = h.canvases.canvas(for: "Debian")
		canvas.open(.config)
		canvas.open(.terminal(console))
		canvas.split(.terminal(console))
		h.canvases.setCanvas(canvas, for: "Debian")
		var publishes = 0
		let watch = h.viewModel.objectWillChange.sink { publishes += 1 }
		var op = Samples.copyOperation()
		for fraction in [0.2, 0.4, 0.6] {
			op.fraction = fraction
			h.stub.emit(.operationChanged(op: op))
			#expect(await eventually { h.operations.operations.first?.fraction == fraction })
		}
		for fraction in [0.3, 0.35, 0.4] {
			canvas.setFraction(fraction, at: 0)
			h.canvases.setCanvas(canvas, for: "Debian")
		}
		watch.cancel()
		#expect(publishes == 0)
	}

	@Test("P9: an install republishes the view model only when its stage changes")
	func anInstallRepublishesOnItsStage() async throws {
		let h = await DesktopHarness.make()
		var publishes = 0
		let watch = h.viewModel.objectWillChange.sink { publishes += 1 }
		func emit(_ kind: InstallPhase.Kind, _ fraction: Double) async {
			h.stub.emit(.installPhaseChanged(vm: "Sequoia", phase: InstallPhase(
				kind: kind, version: "15.4", progress: ProgressInfo(fraction: fraction))))
			_ = await eventually {
				h.operations.installPhases["Sequoia"]?.progress?.fraction == fraction
			}
		}
		await emit(.downloading, 0.1)
		#expect(publishes == 1)
		await emit(.downloading, 0.2)
		await emit(.downloading, 0.3)
		#expect(publishes == 1)
		await emit(.installing, 0.05)
		#expect(publishes == 2)
		watch.cancel()
		let sequoia = try #require(h.viewModel.vms.first { $0.name == "Sequoia" })
		#expect(h.viewModel.isInstalling(sequoia))
	}
}
