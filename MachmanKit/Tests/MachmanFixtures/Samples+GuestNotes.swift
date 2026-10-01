//
//  Samples+GuestNotes.swift
//  MachmanFixtures
//
//  Guest-setup report states: a clean run that noted something (wave 2, lane 2a).
//

import Foundation
import MachmanAPI

extension Samples {
	// A running Linux VM whose last setup run went through clean but re-enabled rc.local on
	// the way (the script's own report_note text): the Guest Setup inspector lists it under
	// Notes, never under Errors.
	public static func setupNotes(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.setup?.lastRunStatus = "ok"
		vm.setup?.notes = [
			GuestSetupNote(
				step: "report-refresh",
				message: "/etc/rc.local was not executable — re-enabled "
					+ "(Machman's boot hook lives there)"),
		]
		return vm
	}
}
