//
//  SSHSessionInspector.swift
//  MachmanDesktopUI
//
//  One ephemeral SSH session's inspector: a renamable display name (identity stays the
//  ref — tabs never re-key), the live target, and a ticking duration. Sessions have no
//  device and no persistence, so there is nothing else to configure.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct SSHSessionInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var profiles: TerminalProfileStore
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
			Section("Terminal") {
				Picker("Profile", selection: profileBinding) {
					ForEach(profiles.profiles) { p in
						Text(p.name).tag(p.id)
					}
				}
			}
			Section {
				// A session whose ssh died is worth reviving in place (same tab, same
				// scrollback) — but only if the guest is answering; otherwise the useful
				// action is to find out whether it still is.
				if let controller = sessions.sshController(vm: vm.name, ref: ref),
					!controller.connected {
					if vm.ssh?.reachability == .ready {
						Button("Reconnect") { reconnect() }
					} else {
						Button("Check Connection") { viewModel.refreshSSH(vm.name) }
					}
				}
				Button("Close Session", role: .destructive) {
					sessions.drop(.ssh(ref), vm: vm.name)
					var canvas = viewModel.canvases.canvas(for: vm.name)
					canvas.close(.ssh(ref))
					viewModel.canvases.setCanvas(canvas, for: vm.name)
				}
			}
		}
		.onAppear { draftName = sessions.sshSessionName(vm: vm.name, ref: ref) }
		.id(ref)   // a different session re-seeds the name draft via onAppear
	}

	private func reconnect() {
		guard let arguments = SSHCommand.arguments(for: vm) else { return }
		sessions.reconnectSSHSession(
			vm: vm.name, ref: ref, arguments: arguments,
			profile: sessions.sshSessionProfileID(vm: vm.name, ref: ref)
				.flatMap { profiles.profile(id: $0) } ?? profiles.defaultProfile)
	}

	private var profileBinding: Binding<UUID> {
		Binding(
			get: {
				sessions.sshSessionProfileID(vm: vm.name, ref: ref)
					?? profiles.defaultProfile.id
			},
			set: { id in
				guard let profile = profiles.profile(id: id) else { return }
				sessions.applySSHProfile(vm: vm.name, ref: ref, id: id, profile: profile)
			})
	}

	private static func format(_ seconds: TimeInterval) -> String {
		let s = max(0, Int(seconds))
		return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
	}
}
