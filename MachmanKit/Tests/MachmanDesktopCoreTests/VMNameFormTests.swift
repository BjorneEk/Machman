//
//  VMNameFormTests.swift
//  MachmanDesktopCoreTests
//
//  H22 and C15's desktop half: Duplicate…, Save as New VM and rename send a trimmed name,
//  and a name the VM-name rule or the list refuses is explained before the daemon sees it
//  ("  " used to pass the sheets' isEmpty check).
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct VMNameFormTests {
	@Test func duplicateSendsTheTrimmedNameAndRefusesBlankOnes() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(!h.viewModel.submitCopy(debian, name: "   ", diskIDs: []))
		#expect(h.viewModel.submitCopy(debian, name: "  Debian twin ", diskIDs: []))
		#expect(await eventually { h.viewModel.selectedName == "Debian twin" })
		#expect(h.stub.vms["Debian twin"] != nil)
		#expect(h.stub.calls.filter { $0 == "copyVM" }.count == 1)
	}

	@Test func takenAndHiddenNamesExplainTheDisabledButton() async {
		let h = await DesktopHarness.make()
		#expect(h.viewModel.newVMNameProblem("Sequoia")
			== "A VM named \u{201C}Sequoia\u{201D} already exists")
		#expect(h.viewModel.newVMNameProblem(" Sequoia ")
			== "A VM named \u{201C}Sequoia\u{201D} already exists")
		#expect(h.viewModel.newVMNameProblem(".x") == "A VM name can't start with a dot")
		#expect(h.viewModel.newVMNameProblem("a/b") == "A VM name can't contain \u{201C}/\u{201D}")
		#expect(h.viewModel.newVMNameProblem("  ") == "A VM name can't be empty")
		#expect(h.viewModel.newVMNameProblem("dev copy") == nil)
	}

	@Test func saveAsNewVMSendsTheTrimmedName() async throws {
		let h = await DesktopHarness.make([Samples.linuxSafeRun()])
		let vm = try #require(h.viewModel.vms.first)
		#expect(!h.viewModel.submitSafeSave(vm, name: " .kept"))
		#expect(h.viewModel.submitSafeSave(vm, name: " kept "))
		#expect(await eventually { h.stub.vms["kept"] != nil })
	}

	@Test func renameRefusesAnInvalidNameBeforeTheDaemon() async throws {
		let h = await DesktopHarness.make()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		h.viewModel.requestRename(alpine, to: "a/b", profiles: h.profiles)
		#expect(h.viewModel.presentedError?.message
			== "A VM name can't contain \u{201C}/\u{201D}")
		#expect(h.viewModel.presentedError?.title == "Renaming Alpine failed")
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("renameVM"))
	}

	@Test func renameTrimsTheName() async throws {
		let h = await DesktopHarness.make()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		h.viewModel.requestRename(alpine, to: "  Alpine 2 ", profiles: h.profiles)
		#expect(await eventually { h.viewModel.selectedName == "Alpine 2" })
		#expect(h.stub.vms["Alpine 2"] != nil)
		#expect(h.stub.vms["  Alpine 2 "] == nil)
	}
}
