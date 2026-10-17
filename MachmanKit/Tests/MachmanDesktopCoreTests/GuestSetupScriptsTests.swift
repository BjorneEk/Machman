//
//  GuestSetupScriptsTests.swift
//  MachmanDesktopCoreTests
//
//  The Guest Setup inspector's version rows (S67, the user's decision): Installed — the
//  stored script the guest's report matched, Custom for an imported or changed one, the
//  reported version when the store holds none, Not installed — and Serves, a menu over the
//  host's store with the latest marked and every custom or changed script dated with its VM.
//  Picking pins the VM; Use Custom Script imports a file and pins the VM to it. The menu
//  itself can't be opened offscreen: its items are proved here.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: rules and view model on StubMachman.
@MainActor
struct GuestSetupScriptsTests {
	static func setup(
		installed: String?, status: String? = GuestRunStatus.ok, served: String? = nil,
		reported version: Int? = 3
	) -> GuestSetupInfo {
		GuestSetupInfo(
			installed: true, scriptVersion: version, lastRunStatus: status,
			scripts: Samples.setupScripts(),
			servedScript: served ?? Samples.setupScriptLatest.id, installedScript: installed)
	}

	static func stored(_ entry: GuestSetupScriptInfo) -> String {
		entry.addedAt?.formatted(date: .abbreviated, time: .shortened) ?? "!"
	}

	@Test("S67: Installed reads the matched entry, Custom, the reported version or Not installed")
	func installedReadsWhatRan() {
		let older = Samples.setupScriptOlder.id
		#expect(GuestSetupScripts.installed(Self.setup(installed: older)) == "v2")
		#expect(GuestSetupScripts.installed(Self.setup(
			installed: Samples.setupScriptCustom.id)) == "Custom")
		#expect(GuestSetupScripts.installed(Self.setup(
			installed: Samples.setupScriptChanged.id)) == "Custom")
		// A script the store doesn't hold (an earlier build, before the store) reads its version.
		#expect(GuestSetupScripts.installed(Self.setup(installed: nil, reported: 7)) == "v7")
		#expect(GuestSetupScripts.installed(Self.setup(installed: nil, reported: nil))
			== "Installed")
		// The run's outcome rides the row.
		#expect(GuestSetupScripts.installed(Self.setup(
			installed: older, status: GuestRunStatus.partial)) == "v2, with gaps")
		#expect(GuestSetupScripts.installed(Self.setup(
			installed: older, status: GuestRunStatus.failed)) == "v2, last run failed")
		#expect(GuestSetupScripts.installed(Self.setup(
			installed: nil, status: GuestRunStatus.failed, reported: nil)) == "Last run failed")
		var uninstalled = Self.setup(installed: older)
		uninstalled.installed = false
		#expect(GuestSetupScripts.installed(uninstalled) == "Not installed")
		#expect(GuestSetupScripts.installed(nil) == "Not installed")
	}

	@Test(
		"""
		S67: the Serves menu lists the store with the latest marked and custom entries dated \
		by their VM
		""")
	func theServesMenu() {
		let setup = Self.setup(installed: nil, served: Samples.setupScriptCustom.id)
		let choices = GuestSetupScripts.choices(setup)
		#expect(choices.map(\.title) == [
			"v3 — latest",
			"v2",
			"Changed on Alpine — \(Self.stored(Samples.setupScriptChanged))",
			"Custom \u{201C}install-patched.sh\u{201D} — Debian, "
				+ Self.stored(Samples.setupScriptCustom),
		])
		#expect(choices.filter(\.isServed).map(\.id) == [Samples.setupScriptCustom.id])
		#expect(GuestSetupScripts.serves(setup) == "\u{201C}install-patched.sh\u{201D}")
		#expect(GuestSetupScripts.serves(Self.setup(installed: nil)) == "v3 — latest")
		#expect(GuestSetupScripts.serves(Self.setup(
			installed: nil, served: Samples.setupScriptChanged.id)) == "Changed on Alpine")

		// An earlier build of a version listed twice says when it was stored.
		var twin = Samples.setupScriptLatest
		twin.id = "v3-0000aaaa1111"
		twin.latest = nil
		twin.addedAt = Samples.epoch.addingTimeInterval(-86_400)
		var twins = setup
		twins.scripts = [Samples.setupScriptLatest, twin]
		let day = twin.addedAt?.formatted(date: .abbreviated, time: .omitted) ?? "!"
		#expect(GuestSetupScripts.choices(twins).map(\.title) == ["v3 — latest", "v3 — \(day)"])
	}

	@Test("S67: an older Machman Agent's setup offers no Serves menu")
	func anOlderAgentHasNoMenu() {
		let older = GuestSetupInfo(installed: true, scriptVersion: 7, currentScriptVersion: 8)
		#expect(GuestSetupScripts.serves(older) == nil)
		#expect(GuestSetupScripts.choices(older).isEmpty)
		#expect(GuestSetupScripts.installed(older) == "v7")
	}

	@Test("S67: picking a script pins it, and Use Custom Script imports the file and then pins it")
	func pickAndImport() async throws {
		let h = await DesktopHarness.make([Samples.linux("Debian", state: .running)])
		h.viewModel.setSetupScript("Debian", id: Samples.setupScriptOlder.id)
		#expect(await eventually {
			h.viewModel.vms.first?.setup?.servedScript == Samples.setupScriptOlder.id
		})
		#expect(h.viewModel.toasts.isEmpty)

		h.viewModel.useCustomSetupScript("Debian", path: "/Users/demo/Scripts/mine.sh")
		#expect(await eventually {
			h.viewModel.toasts.contains {
				$0.message == "Added Guest Setup script \u{201C}mine.sh\u{201D}"
			}
		})
		#expect(h.stub.setupScriptImports.map(\.path) == ["/Users/demo/Scripts/mine.sh"])
		#expect(h.stub.setupScriptImports.map(\.vm) == ["Debian"])
		let calls = h.stub.calls.filter { $0.contains("SetupScript") }
		#expect(calls == ["setSetupScript", "importSetupScript", "setSetupScript"])
		// The list that shows it follows the stub's listChanged.
		#expect(await eventually {
			GuestSetupScripts.servedEntry(h.viewModel.vms.first?.setup)?.label == "mine.sh"
		})
		#expect(h.viewModel.presentedError == nil)
	}

	// An older Machman Agent answers the store's methods with -32601 (read as unsupported):
	// the alert says what to do, never "unknown method".
	@Test("S67: an older Machman Agent's -32601 for a pin says to update it")
	func anOlderAgentSaysToUpdate() async throws {
		let h = await DesktopHarness.make([Samples.linux("Debian", state: .running)])
		h.stub.fail(
			"setSetupScript",
			with: MachmanError(code: .unsupported, message: "unknown method 'vm.setup.pin'"))
		h.viewModel.setSetupScript("Debian", id: Samples.setupScriptOlder.id)
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(h.viewModel.presentedError?.title == "Changing the served script failed")
		#expect(h.viewModel.presentedError?.message
			== VMListViewModel.setupScriptsNeedNewerAgent)
		#expect(h.viewModel.vms.first?.setup?.servedScript == Samples.setupScriptLatest.id)
	}
}
