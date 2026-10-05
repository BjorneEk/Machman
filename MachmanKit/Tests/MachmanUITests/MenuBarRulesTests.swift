//
//  MenuBarRulesTests.swift
//  MachmanUITests
//
//  P23: the menu-bar agent's actions failed silently (start and stop only logged, the
//  window items used try?), and Start stayed enabled during a macOS install. What its alert
//  says, when it offers Start Anyway, and when Start waits are pure rules, pinned here. V11:
//  its Shut Down and Force Stop were disabled exactly for the VMs it couldn't see a state for
//  — the ones it counts as running when it quits — while Start stayed enabled for them.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanFixtures
import MachmanAPI
import MachmanUI

struct MenuBarRulesTests {
	private let refused = MachmanError(code: .invalidState, message: "Debian is installing")
	private let conflict = MachmanError(
		code: .macConflict, message: "Alpine already uses 5e:2c:7a:10:44:01")

	@Test func eachActionNamesWhatFailed() {
		let start = MenuBarFailure(vm: "Debian", action: .start(StartOptions()), error: refused)
		#expect(start.title == "Couldn’t start \u{201C}Debian\u{201D}")
		#expect(start.message == "Debian is installing")
		#expect(start.forceStart == nil)
		#expect(MenuBarFailure(vm: "Debian", action: .stop(.soft), error: refused).title
			== "Couldn’t shut down \u{201C}Debian\u{201D}")
		#expect(MenuBarFailure(vm: "Debian", action: .stop(.force), error: refused).title
			== "Couldn’t force stop \u{201C}Debian\u{201D}")
		#expect(MenuBarFailure(vm: "Debian", action: .openWindow, error: refused).title
			== "Couldn’t open Debian’s window")
		#expect(MenuBarFailure(vm: "Debian", action: .closeWindow, error: refused).title
			== "Couldn’t close Debian’s window")
	}

	// As the desktop: a MAC conflict offers the same start, forced.
	@Test func aMACConflictOffersStartAnyway() {
		let failure = MenuBarFailure(
			vm: "Debian", action: .start(StartOptions(openWindow: false, safe: true)),
			error: conflict)
		#expect(failure.title == "MAC address conflict")
		#expect(failure.message == "Alpine already uses 5e:2c:7a:10:44:01")
		#expect(failure.forceStart == StartOptions(openWindow: false, force: true, safe: true))
		// A forced start that conflicts anyway is only reported.
		let again = MenuBarFailure(
			vm: "Debian", action: .start(StartOptions(force: true)), error: conflict)
		#expect(again.forceStart == nil)
		#expect(MenuBarFailure(vm: "Debian", action: .stop(.soft), error: conflict)
			.forceStart == nil)
	}

	@Test func aForeignErrorUsesItsDescription() {
		struct Unreachable: LocalizedError {
			var errorDescription: String? { "the agent's socket is gone" }
		}
		#expect(MenuBarFailure(vm: "Debian", action: .openWindow, error: Unreachable())
			.message == "the agent's socket is gone")
	}

	// E28: an NSError reads its own sentence, never "Error Domain=… Code=…".
	@Test func anNSErrorUsesItsLocalizedDescription() {
		let error = NSError(domain: "VZErrorDomain", code: 1, userInfo: [
			NSLocalizedDescriptionKey: "The window can’t open.",
		])
		let failure = MenuBarFailure(vm: "Debian", action: .openWindow, error: error)
		#expect(failure.message == "The window can’t open.")
	}

	@Test func startWaitsForAMacOSInstall() {
		var mac = VMInfo(
			name: "Sequoia", state: .stopped, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 4, memoryBytes: 8 << 30, macAddress: nil, disks: [],
			mounts: [],
			boot: BootInfo(
				mode: .macOS, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
		#expect(mac.isInstallingMacOS(phase: .downloading))
		#expect(!mac.isInstallingMacOS(phase: nil))
		mac.boot.macInstallState = MacInstallState(kind: .installing)
		#expect(mac.isInstallingMacOS(phase: nil))
		// A live phase wins over the listed state.
		#expect(!mac.isInstallingMacOS(phase: .installed))
		mac.boot.macInstallState = MacInstallState(kind: .interrupted)
		#expect(!mac.isInstallingMacOS(phase: nil))
	}

	// Unknown is busy (VMBusyRule): stop offered, Start held, as for a VM not answering.
	@Test func unknownIsBusyInTheAgentsMenu() {
		let cases: [(VMInfo, start: Bool, stop: Bool)] = [
			(Samples.linux("Alpine"), true, false),
			(Samples.linux("Fedora", state: .error), true, false),
			(Samples.linux("Debian", state: .starting), false, true),
			(Samples.linux("Debian", state: .running), false, true),
			(Samples.linux("Debian", state: .stopping), false, true),
			(Samples.linux("Debian", state: .paused), false, true),
			(Samples.linux("Debian", state: .unknown), false, true),
			(Samples.neverAnswered("Debian"), false, true),
			(Samples.notResponding("Debian"), false, true),
		]
		for (vm, start, stop) in cases {
			let label = "\(vm.state) unresponsive: \(vm.isUnresponsive)"
			#expect(vm.menuBarCanStart(phase: nil) == start, "\(label)")
			#expect(vm.menuBarCanStop == stop, "\(label)")
		}
	}
}
