//
//  VMHostQuitTests.swift
//  MachmanTests
//
//  V1: quitting a vmhost whose VM runs — by ⌘Q, or by the Mac logging out, restarting or
//  shutting down — stays cancelled (decision 6), but the prompt says why and what to do.
//  Prompts are answered through the presenter's seam (TestVMHost); the activation itself
//  is AppKit, so only its rules are tested here.
//

import Testing
import Foundation
import AppKit
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct VMHostQuitTests {
	@Test func quitReasonsMapFromTheAppleEvent() {
		let cases: [(OSType?, VMHostQuitReason)] = [
			(OSType(kAELogOut), .logOut), (OSType(kAEReallyLogOut), .logOut),
			(OSType(kAEShowRestartDialog), .restart), (OSType(kAERestart), .restart),
			(OSType(kAEShowShutdownDialog), .shutDown), (OSType(kAEShutDown), .shutDown),
			(nil, .userQuit),                               // ⌘Q, the Dock's Quit
			(OSType(kAEOpenApplication), .userQuit),        // anything else
		]
		for (code, reason) in cases {
			#expect(VMHostQuitReason(appleEventCode: code) == reason, "\(String(describing: code))")
		}
	}

	// No quit Apple event is being handled here, as with ⌘Q.
	@Test func withoutAQuitEventItIsTheUsersQuit() {
		#expect(VMHostQuitReason.current() == .userQuit)
	}

	// Q23: the lab quits a test-suite vmhost on its control socket, for a chosen reason that
	// is stored before the quit and read in place of the (absent) quit event's, once.
	@Test("Q23: a lab quit's reason stands in for the quit event's, once")
	func aLabQuitsReasonStandsInOnce() {
		let host = TestVMHost()
		host.delegate.labQuitReason = .logOut
		#expect(host.delegate.takeQuitReason(event: { .userQuit }) == .logOut)
		#expect(host.delegate.takeQuitReason(event: { .shutDown }) == .shutDown)
		#expect(host.delegate.takeQuitReason() == .userQuit)   // no quit event here
		host.delegate.labQuitReason = .restart
		#expect(host.delegate.terminateReply(for: host.delegate.takeQuitReason())
			== .terminateCancel)
		#expect(host.prompts == [.quitWhileRunning("alpha", reason: .restart)])
	}

	@Test(arguments: [
		(VMHostQuitReason.logOut, "then log out again."),
		(.restart, "then restart again."),
		(.shutDown, "then shut down your Mac again."),
	])
	func aLogOutIsStillCancelledButSaysWhatToDo(reason: VMHostQuitReason, retry: String) async {
		let host = TestVMHost { $0.message == "alpha is still running" ? .shutDown : .keepWaiting }
		#expect(host.delegate.terminateReply(for: reason) == .terminateCancel)
		let prompt = host.prompts.first
		#expect(prompt == .quitWhileRunning("alpha", reason: reason))
		#expect(prompt?.message == "alpha is still running")
		#expect(prompt?.info.hasSuffix(retry) == true)
		#expect(prompt.map { $0.buttons.map(\.title) }
			== ["Shut Down VM", "Force Stop VM", "Keep Running"])
		// Shut Down VM asks the guest and follows up like every other Shut Down.
		#expect(await eventually { host.prompts.last == .notShutDownYet("alpha") })
		#expect(host.stops == [.soft])
	}

	// Decision 6: nothing is stopped on the log out's own initiative.
	@Test(arguments: [VMHostQuitReason.logOut, .restart, .shutDown])
	func keepRunningStopsNothing(reason: VMHostQuitReason) {
		let host = TestVMHost { _ in .cancel }
		#expect(host.delegate.terminateReply(for: reason) == .terminateCancel)
		#expect(host.prompts.count == 1)
		#expect(host.stops.isEmpty)
		#expect(host.prompts.first?.escapeButton == 2)    // Esc is Keep Running
	}

	@Test(arguments: [VMHostQuitReason.logOut, .restart, .shutDown])
	func anIdleHostLetsTheLogOutProceed(reason: VMHostQuitReason) {
		let host = TestVMHost(running: false)
		#expect(host.delegate.terminateReply(for: reason) == .terminateNow)
		#expect(host.prompts.isEmpty)
	}

	static let importing = OperationInfo(
		id: "op-1", kind: OperationInfo.Kind.importDisk, vm: "alpha", label: "Importing big.raw",
		startedAt: Date(), cancellable: true)

	// E46: a vmhost still finishing an import into its stopped VM (E34's drain) answered a
	// log out with terminateNow, and the import died with it. It cancels now, and its alert
	// says why after the reply.
	@Test(
		"E46: a log out while the vmhost finishes an import is canceled, and it says why",
		arguments: [VMHostQuitReason.logOut, .restart, .shutDown])
	func aSessionEndWaitsForAnImport(reason: VMHostQuitReason) async {
		let host = TestVMHost(running: false)
		host.operations = [Self.importing]
		#expect(host.delegate.terminateReply(for: reason) == .terminateCancel)
		#expect(host.prompts.isEmpty)   // the alert comes after the reply
		#expect(await eventually { !host.prompts.isEmpty })
		let prompt = host.prompts.first
		#expect(prompt == .sessionEndDuringWork(
			"alpha", activity: "is importing a disk", reason: reason))
		#expect(prompt?.message == "alpha is importing a disk")
		let (canceled, again) = reason.canceled
		#expect(prompt?.info == "\(canceled): wait for it to finish, then \(again).")
		#expect(prompt.map { $0.buttons.map(\.title) } == ["OK"])
		#expect(host.stops.isEmpty)
		// Once the import is done, the next log out goes through.
		host.operations = []
		#expect(host.delegate.terminateReply(for: reason) == .terminateNow)
	}

	// Decision 16: a prompt's info is one sentence. "Debian 12.4" keeps a name's dots honest.
	@Test func everyPromptIsOneSentence() throws {
		let name = "Debian 12.4"
		var prompts: [HostPrompt] = [
			.closeWhileRunning(name), .notShutDownYet(name), .shutDownRefused(name),
			.forceStopFailed(name, reason: "\(name) is not running."),
		]
		for reason in [VMHostQuitReason.userQuit, .logOut, .restart, .shutDown] {
			prompts.append(.quitWhileRunning(name, reason: reason))
			prompts.append(.sessionEndDuringWork(
				name, activity: "is importing a disk", reason: reason))
		}
		let sentenceEnd = try Regex(#"[.?!](\s|$)"#)
		for prompt in prompts {
			let info = prompt.info.replacingOccurrences(of: name, with: "the VM")
			#expect(info.matches(of: sentenceEnd).count == 1, "\(prompt.info)")
		}
	}

	// Only a vmhost (which manages its policy) lends itself a Dock icon, and only while it
	// has none; it gives it back unless a window opened meanwhile.
	@Test func promptActivation() {
		#expect(PromptActivation.lendsDockIcon(managesPolicy: true, current: .accessory))
		#expect(PromptActivation.lendsDockIcon(managesPolicy: true, current: .prohibited))
		#expect(!PromptActivation.lendsDockIcon(managesPolicy: true, current: .regular))
		#expect(!PromptActivation.lendsDockIcon(managesPolicy: false, current: .accessory))

		#expect(PromptActivation.returnsToAccessory(lent: true, windowsOpen: false))
		#expect(!PromptActivation.returnsToAccessory(lent: true, windowsOpen: true))
		#expect(!PromptActivation.returnsToAccessory(lent: false, windowsOpen: false))
	}

	// Return stays on the default; Esc goes to a cancel AppKit wouldn't find by its title.
	@Test func escapeFindsTheCancelButtonOnly() {
		#expect(HostPrompt.closeWhileRunning("alpha").escapeButton == nil)    // "Cancel"
		#expect(HostPrompt.shutDownRefused("alpha").escapeButton == nil)      // the default
		#expect(HostPrompt.forceStopFailed("alpha", reason: "x.").escapeButton == nil)
		#expect(HostPrompt.notShutDownYet("alpha").escapeButton == nil)
	}
}
