//
//  RosettaHelpSheet.swift
//  MachmanDesktopUI
//
//  Rosetta inside a Linux guest (X4): mount Apple's share, register its interpreter — and
//  mount binfmt_misc first where the guest's init doesn't. Steps only, the guide's look
//  (HelpSheet.swift), with the Guest Setup guide's run-as choice above them.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct RosettaHelpSheet: View {
	// Linux guests' choices, sudo first; a root console or a doas guest picks its own.
	private let choices = GuestSetupCommands.escalations(for: .linux)
	@State private var escalation: GuestEscalation

	// `escalation` opens the sheet on that choice (render scenes).
	init(escalation: GuestEscalation? = nil) {
		_escalation = State(
			initialValue: escalation ?? GuestSetupCommands.escalations(for: .linux)[0])
	}

	var body: some View {
		HelpSheetFrame(
			symbol: MachmanSymbols.deviceRosetta, title: "Rosetta in the Guest", height: 560
		) {
			HelpRunAsPicker(choices: choices, selection: $escalation)
		} page: {
			RosettaGuidePage(escalation: escalation)
		}
	}
}

// The sheet's page, apart from it so a render can show it whole.
struct RosettaGuidePage: View {
	var escalation: GuestEscalation = .sudo

	var body: some View {
		HelpStep(1, "Mount the share:")
		HelpCommand(GuestSetupCommands.rosettaMount(escalation))
		HelpStep(2, "Register Rosetta for x86-64 binaries:")
		HelpCommand(GuestSetupCommands.rosettaRegister(escalation))
		HelpNote("If that says “No such file or directory”, mount binfmt_misc and run it again:")
		HelpCommand(GuestSetupCommands.binfmtMiscMount(escalation))
		HelpNote("Everything here lasts until the guest restarts.")
	}
}
