//
//  EngineLogToastTests.swift
//  MachmanDesktopCoreTests
//
//  W3 (E9): an engine warning shows as "<VM>: <sentence>". An older daemon's warning already
//  started with the VM's name, so the toast read "Debian: Debian has no display device…".
//  A message that starts with its VM's name stands as it is: the VM is named once.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct EngineLogToastTests {
	@Test func anOlderDaemonsWarningNamesTheVMOnce() async {
		let h = await DesktopHarness.make()
		let message = Samples.olderDaemonBootWarning("Debian")
		h.stub.emit(.log(vm: "Debian", level: .warning, message: message))
		#expect(await eventually { h.viewModel.toasts.contains { $0.message == message } })
		#expect(!h.viewModel.toasts.contains { $0.message.hasPrefix("Debian: Debian") })
	}

	@Test func aCurrentWarningIsPrefixedWithItsVM() async {
		let h = await DesktopHarness.make()
		h.stub.emit(.log(vm: "Debian", level: .warning, message: Samples.bootWarning))
		let text = "Debian: " + Samples.bootWarning
		#expect(await eventually { h.viewModel.toasts.contains { $0.message == text } })
		#expect(await eventually {
			h.operations.activity.entries.contains {
				$0.vm == "Debian" && $0.detail == Samples.bootWarning
			}
		})
	}

	@Test func theNameMustEndOnAWordBoundary() {
		#expect(VMListViewModel.engineLogText(vm: "Deb", message: "Debian x") == "Deb: Debian x")
		#expect(VMListViewModel.engineLogText(vm: "Debian", message: "Debian") == "Debian")
		#expect(VMListViewModel.engineLogText(vm: nil, message: "x") == "x")
	}
}
