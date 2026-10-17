//
//  MenuRulesTests.swift
//  MachmanDesktopCoreTests
//
//  The menu rules every surface shares (VMMenuRules). P14: what the daemon refuses on a
//  running VM (RoutingMachman.requireStopped) is offered disabled with a one-sentence reason
//  while the VM is hosted — running, starting or not answering — and offered plainly
//  otherwise.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct MenuRulesTests {
	@Test func everyStopFirstActionIsRefusedWhileRunning() {
		let hosted = [
			Samples.linux("Debian", state: .running), Samples.linux("Debian", state: .starting),
			Samples.notResponding(),
		]
		for vm in hosted {
			for action in StoppedOnly.allCases {
				#expect(vm.refusal(action) == action.stopFirst, "\(vm.state) \(action)")
			}
		}
		let stopped = [Samples.linux("Alpine"), Samples.linux("Fedora", state: .error)]
		for vm in stopped {
			for action in StoppedOnly.allCases {
				#expect(vm.refusal(action) == nil, "\(vm.state) \(action)")
			}
		}
	}

	// P37: unknown is busy — Machman Agent hasn't reached the VM's vmhost, which may well run,
	// so every stop-first action waits for it (before: all offered, and refused by the agent).
	@Test func everyStopFirstActionWaitsWhileTheStateIsUnknown() {
		for vm in [Samples.unreached(), Samples.neverAnswered()] {
			for action in StoppedOnly.allCases {
				#expect(vm.refusal(action) == VMInfo.unreachedHelp, "\(action)")
			}
		}
	}

	// H10: the installers menu offers the unified Guest Setup, once.
	@Test func guestSetupIsOfferedOnlyWhenAbsent() {
		#expect(!Samples.linux("Debian").canAddGuestSetup)
		#expect(Samples.macOS("Sequoia").canAddGuestSetup)
		var disabled = Samples.macOS("Sequoia")
		disabled.devices = (disabled.devices ?? [])
			+ [DeviceInfo(kind: .guestSetup, enabled: false)]
		#expect(!disabled.canAddGuestSetup)
	}

	@Test("Q30: the Installers group shows only once Guest Setup is attached, nothing to add")
	func theInstallersGroupHasNothingToAdd() {
		var disabled = Samples.linux("Debian")
		disabled.devices = (disabled.devices ?? []).map {
			$0.kind == .guestSetup ? DeviceInfo(kind: .guestSetup, enabled: false) : $0
		}
		for vm in Samples.library() + [disabled, Samples.macOS("Sequoia")] {
			let installers = (vm.devices ?? []).filter(\.kind.isInstaller).count
			if TreeSection.isVisible(.installers, rows: installers, filtering: false) {
				#expect(!vm.canAddGuestSetup, "\(vm.name)")
			}
		}
	}

	// Decision 16: a tooltip is one short sentence.
	@Test func reasonsAreOneShortSentence() {
		for action in StoppedOnly.allCases {
			let reason = action.stopFirst
			#expect(reason.hasPrefix("Stop the VM to "), "\(reason)")
			#expect(!reason.hasSuffix("."), "\(reason)")
			#expect(reason.count <= 60, "\(reason)")
		}
		#expect(!VMInfo.unreachedHelp.hasSuffix("."))
		#expect(VMInfo.unreachedHelp.count <= 60)
	}

	// H41: a stop-first case with no surface gating on it (installMacOS was one) leaves the
	// action live in the UI and refused by the daemon after the click. Each case is asked of
	// some desktop view, command or menu model: `.stopFirst(vm, .case)` or `refusal(.case)`.
	@Test("H41: every stop-first action has a UI that refuses it")
	func everyStopFirstActionHasAUI() throws {
		let files = RepoFiles.files(
			under: [
				"MachmanKit/Sources/MachmanDesktopUI", "MachmanKit/Sources/MachmanDesktopCore",
				"MachmanDesktop",
			], extension: "swift")
		#expect(files.count > 20, "the scan found too few files")
		let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }
			.joined(separator: "\n")
		for action in StoppedOnly.allCases {
			let name = String(describing: action)
			let pattern = try NSRegularExpression(
				pattern: #"(stopFirst\([^)]*,\s*|refusal\()\."# + name + #"\b"#)
			let found = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
			#expect(found != nil, "no desktop surface gates on .\(name)")
		}
	}
}
