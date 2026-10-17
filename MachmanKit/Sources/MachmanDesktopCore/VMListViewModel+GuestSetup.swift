//
//  VMListViewModel+GuestSetup.swift
//  MachmanDesktopCore
//
//  Guest Setup's requests: forget the report, serve the installer to an installed guest, and
//  the script store (S67) — pin the VM to a stored script, or import a script file and pin
//  the VM to it. An older Machman Agent has no store: its -32601 says to update it.
//

import Foundation
import MachmanUI
import MachmanAPI

extension VMListViewModel {
	public func resetSetup(_ name: String) {
		perform(
			"Resetting guest setup state",
			toast: ActionToast(
				symbol: MachmanSymbols.deviceGuestSetup,
				message: "Guest setup state reset for \(name)")
		) { try await $0.resetSetup(vm: name) }
	}

	// The Allow-reinstall toggle made real: serving on demand, clean share otherwise.
	public func setSetupServed(_ name: String, serve: Bool) {
		perform("Changing the reinstall setting") {
			try await $0.setSetupServed(vm: name, serve: serve)
		}
	}

	// What an older Machman Agent's -32601 for the script store becomes: what to do.
	public static let setupScriptsNeedNewerAgent = "The running Machman Agent is too old to "
		+ "choose Guest Setup scripts — quit it from its menu-bar item to update it"

	// Serves: the VM serves this stored script from now on. The row shows it: no toast.
	public func setSetupScript(_ name: String, id: String) {
		perform("Changing the served script") { api in
			try await Self.onNewerAgent { try await api.setSetupScript(vm: name, id: id) }
		}
	}

	// Use Custom Script…: the file joins the store, named and dated for this VM, which then
	// serves it.
	public func useCustomSetupScript(_ name: String, path: String) {
		let file = (path as NSString).lastPathComponent
		perform(
			"Adding the Guest Setup script",
			toast: ActionToast(
				symbol: MachmanSymbols.deviceGuestSetup,
				message: "Added Guest Setup script \u{201C}\(file)\u{201D}")
		) { api in
			try await Self.onNewerAgent {
				let entry = try await api.importSetupScript(path: path, vm: name)
				return try await api.setSetupScript(vm: name, id: entry.id)
			}
		}
	}

	private static func onNewerAgent<Value>(
		_ call: @MainActor () async throws -> Value
	) async throws -> Value {
		do {
			return try await call()
		} catch let error as MachmanError where error.code == .unsupported {
			throw MachmanError(code: .unsupported, message: setupScriptsNeedNewerAgent)
		}
	}
}
