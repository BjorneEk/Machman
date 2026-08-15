//
//  SSHSessionInspector.swift
//  MachmanDesktop
//
//  One ephemeral SSH session's inspector: a renamable display name (identity stays the
//  ref — tabs never re-key), the live target, and a ticking duration. Sessions have no
//  device and no persistence, so there is nothing else to configure.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct SSHSessionInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	let vm: VMInfo
	let ref: SSHSessionRef
	@State private var draftName = ""

	var body: some View {
		Form {
			Section("SSH Session") {
				TextField("Name", text: $draftName)
					.onSubmit {
						sessions.renameSSHSession(vm: vm.name, ref: ref, to: draftName)
					}
				if let user = vm.ssh?.guestUser, let address = vm.ssh?.address {
					LabeledContent("Target") {
						Text("\(user)@\(address)")
							.font(.system(.callout, design: .monospaced))
					}
				}
				if let started = sessions.sshSessionStart(vm: vm.name, ref: ref) {
					TimelineView(.periodic(from: .now, by: 1)) { _ in
						LabeledContent("Duration") {
							Text(Self.format(Date().timeIntervalSince(started)))
								.monospacedDigit()
						}
					}
				}
			}
			Section {
				Button("Close Session", role: .destructive) {
					sessions.dropSSHController(vm: vm.name, ref: ref)
					var canvas = viewModel.canvases.canvas(for: vm.name)
					canvas.close(.ssh(ref))
					viewModel.canvases.setCanvas(canvas, for: vm.name)
				}
			}
		}
		.onAppear { draftName = sessions.sshSessionName(vm: vm.name, ref: ref) }
		.id(ref)   // a different session re-seeds the name draft via onAppear
	}

	private static func format(_ seconds: TimeInterval) -> String {
		let s = max(0, Int(seconds))
		return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
	}
}
