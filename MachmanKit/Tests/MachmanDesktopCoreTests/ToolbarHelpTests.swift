//
//  ToolbarHelpTests.swift
//  MachmanDesktopCoreTests
//
//  W4: the toolbar Start's tooltip (also its VoiceOver name) was built by concatenation,
//  “Start (headless) (safe)”, and a Mac that was installing read as a semicolon splice. It
//  names the policy's start the way the Run menu does now; the window toggle says what a
//  start will do instead of “Window opens on start (default: on)”.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct ToolbarHelpTests {
	private func alpine(windowed: Bool, safe: Bool) -> VMInfo {
		var vm = Samples.linux("Alpine")
		vm.startPolicy = StartPolicy(windowed: windowed, safe: safe)
		return vm
	}

	@Test func aPlainStartSaysWhatThePolicyDoes() async {
		let h = await DesktopHarness.make([Samples.linux("Alpine")])
		#expect(h.viewModel.startHelp(alpine(windowed: true, safe: false)) == "Start")
		#expect(h.viewModel.startHelp(alpine(windowed: false, safe: false)) == "Start Headless")
		#expect(h.viewModel.startHelp(alpine(windowed: true, safe: true)) == "Start Safe")
		#expect(h.viewModel.startHelp(alpine(windowed: false, safe: true))
			== "Start Headless and Safe")
	}

	@Test func anInstallingMacSaysToWait() async throws {
		let h = await DesktopHarness.make([Samples.macOS("Sequoia")])
		h.stub.emit(.installPhaseChanged(vm: "Sequoia", phase: Samples.downloadingMacInstall()))
		let mac = try #require(h.viewModel.vms.first)
		#expect(await eventually { h.viewModel.isInstalling(mac) })
		#expect(h.viewModel.startHelp(mac) == "Wait for the macOS install to finish")
	}

	@Test func theWindowToggleSaysWhatAStartWillDo() {
		#expect(VMListViewModel.windowToggleHelp(alpine(windowed: true, safe: false))
			== "The window opens when the VM starts")
		#expect(VMListViewModel.windowToggleHelp(alpine(windowed: false, safe: true))
			== "The VM starts without a window")
		var running = Samples.linux("Debian", state: .running)
		running.windowOpen = true
		#expect(VMListViewModel.windowToggleHelp(running)
			== "Close Window — the VM keeps running")
		running.windowOpen = false
		#expect(VMListViewModel.windowToggleHelp(running) == "Open Window")
	}
}
