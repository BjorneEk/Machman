//
//  InspectorChrome.swift
//  MachmanDesktopUI
//
//  What every inspector column wraps its entity inspector in, the main window's and a torn
//  window's alike (H40): while an older vmhost runs the VM, the restart banner and the
//  settings lock (E22, decision 9), and the grouped form style. A session's own inspector is
//  desktop-local and stays live, and so does what changes no setting inside the others
//  (SettingsLock.swift).
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct InspectorChrome<Content: View>: View {
	let vm: VMInfo
	// The inspector shows an SSH session, which changes nothing on the VM.
	let session: Bool
	@ViewBuilder let content: Content

	var body: some View {
		VStack(spacing: 0) {
			if let reason = vm.restartToUpdate {
				RestartToUpdateBanner(message: reason)
				Divider()
			}
			content
				.settingsLocked(vm.restartToUpdate != nil && !session)
		}
		.formStyle(.grouped)
	}
}
