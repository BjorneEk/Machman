//
//  RosettaHelpSheet.swift
//  MachmanDesktopUI
//
//  Rosetta inside a Linux guest (X4): mount Apple's share, register its interpreter. Steps
//  only, the guide's look (HelpSheet.swift).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct RosettaHelpSheet: View {
	var body: some View {
		HelpSheetFrame(
			symbol: MachmanSymbols.deviceRosetta, title: "Rosetta in the Guest", height: 440
		) {
			EmptyView()
		} page: {
			RosettaGuidePage()
		}
	}
}

// The sheet's page, apart from it so a render can show it whole.
struct RosettaGuidePage: View {
	var body: some View {
		HelpStep(1, "Mount the share:")
		HelpCommand(GuestSetupCommands.rosettaMount())
		HelpStep(2, "Register Rosetta for x86-64 binaries:")
		HelpCommand(GuestSetupCommands.rosettaRegister())
		HelpNote("Both last until the guest restarts.")
	}
}
