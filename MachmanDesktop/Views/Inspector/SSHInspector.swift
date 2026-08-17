//
//  SSHInspector.swift
//  MachmanDesktop
//
//  EVERYTHING SSH for one VM, in one place: the tree's SSH section is its home, and the
//  SSH Setup device row routes here too. It used to be spread across the network device
//  (status, alias, guest access) and the installer device (payload, guide, reset), which
//  meant reading two inspectors to answer one question.
//

import SwiftUI
import CryptoKit
import MachmanUI
import MachmanAPI

// OpenSSH-style fingerprint of a public-key line ("SHA256:…") for approval dialogs.
private func sshKeyFingerprint(_ keyLine: String) -> String? {
	let fields = keyLine.split(separator: " ")
	guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
		return nil
	}
	let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
	return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
}

// The status-and-switches half of the SSH inspector: who the guest is, the command that
// reaches it, the managed ~/.ssh entry and its name, and guest→host access. The address
// itself stays with the network device (it needs no SSH). Switches are consent-gated.
struct NetworkSSHSection: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@State private var integrationConsent = false
	@State private var approveConsent = false
	@State private var revokeConsent = false

	@State private var aliasDraft = ""

	private var setupAttached: Bool {
		(vm.devices ?? []).contains { $0.kind == .sshInstaller }
	}
	// Served, never derived: the VM can be named something else in ~/.ssh.
	private var alias: String { vm.ssh?.alias ?? "\(vm.name).machman" }
	private var sshCommand: String? {
		guard let ssh = vm.ssh else { return nil }
		if ssh.integrationEnabled == true {
			return "ssh \"\(alias)\""
		}
		// Self-contained command — works without the ~/.ssh integration.
		guard let user = ssh.guestUser, let address = ssh.address,
			let identity = ssh.identityFilePath else { return nil }
		return "ssh -i '\(identity)' -o IdentitiesOnly=yes \(user)@\(address)"
	}

	var body: some View {
		Section("SSH") {
			if vm.ssh == nil && !setupAttached {
				Text("Add the SSH Setup installer to reach this VM over SSH — it enables "
					+ "sshd in the guest and exchanges keys with this Mac.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Button("Add SSH Setup") {
					viewModel.addDevice(vm.name, kind: .sshInstaller)
				}
			} else {
				statusRows
			}
		}
	}

	@ViewBuilder
	private var statusRows: some View {
		LabeledContent("Guest user") {
			Text(vm.ssh?.guestUser ?? "— run the setup script in the guest")
				.font(.system(.callout, design: .monospaced))
				.foregroundStyle(vm.ssh?.guestUser == nil ? .secondary : .primary)
		}
		if let hostname = vm.ssh?.guestHostname {
			LabeledContent("Hostname") {
				Text(hostname).font(.system(.callout, design: .monospaced))
			}
		}
		if let command = sshCommand {
			CommandBlock(command)
		}
		integrationToggle
		aliasField
		reverseRows
	}

	// The name this VM answers to — in ~/.ssh and in the session tabs' host-key pin.
	// A plain Form TextField (the Machine section's Name field, same shape): a value the
	// user types has to LOOK typed-in, not like a label that happens to be selectable.
	private var aliasField: some View {
		VStack(alignment: .leading, spacing: 3) {
			TextField("Alias", text: $aliasDraft)
				.onSubmit { viewModel.setSSHAlias(vm.name, alias: aliasDraft) }
			if aliasDraft != alias {
				Text("Press Return to rename.")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			} else if !aliasDraft.contains(".") && !aliasDraft.isEmpty {
				Text("A plain name can shadow a real host in your SSH config.")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
		.onAppear { aliasDraft = alias }
		.onChange(of: alias) { aliasDraft = alias }
	}

	private var integrationToggle: some View {
		Toggle(isOn: Binding(
			get: { vm.ssh?.integrationEnabled == true },
			set: { enable in
				if enable {
					integrationConsent = true   // the dialog confirms before any write
				} else {
					viewModel.setSSHIntegration(vm.name, enabled: false)
				}
			})) {
			VStack(alignment: .leading, spacing: 2) {
				Text("Terminal alias")
				Text("ssh \"\(alias)\" from any terminal")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
		.confirmationDialog(
			"Add \(alias) to your SSH config?", isPresented: $integrationConsent
		) {
			Button("Add to ~/.ssh") { viewModel.setSSHIntegration(vm.name, enabled: true) }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Adds one marked Include line to ~/.ssh/config plus a Machman-owned "
				+ "entry per VM — your own entries are never touched.")
		}
	}

	@ViewBuilder
	private var reverseRows: some View {
		switch vm.ssh?.reverseState ?? SSHInfo.ReverseState.none {
		case .pending:
			LabeledContent("Guest → Mac") {
				Text("awaiting your approval").foregroundStyle(.secondary)
			}
			if let fingerprint = vm.ssh?.reversePublicKey.flatMap(sshKeyFingerprint) {
				Text(fingerprint)
					.font(.system(.caption2, design: .monospaced))
					.foregroundStyle(.tertiary)
					.textSelection(.enabled)
			}
			HStack {
				Button("Approve…") { approveConsent = true }
					.confirmationDialog(
						"Let \(vm.name) log in to this Mac as you?",
						isPresented: $approveConsent
					) {
						Button("Approve") {
							viewModel.setSSHReverseApproved(vm.name, approved: true)
						}
						Button("Cancel", role: .cancel) {}
					} message: {
						Text("Adds the key shown above to ~/.ssh/authorized_keys — needs "
							+ "Remote Login enabled on this Mac.")
					}
				// An answer, not a postponement: denying stops the asking until the guest
				// reports a different key.
				Button("Deny") { viewModel.setSSHReverseApproved(vm.name, approved: false) }
			}
		case .denied:
			LabeledContent("Guest → Mac") {
				Text("denied").foregroundStyle(.secondary)
			}
			Button("Approve…") { approveConsent = true }
				.confirmationDialog(
					"Let \(vm.name) log in to this Mac as you?", isPresented: $approveConsent
				) {
					Button("Approve") {
						viewModel.setSSHReverseApproved(vm.name, approved: true)
					}
					Button("Cancel", role: .cancel) {}
				} message: {
					Text("Adds the key shown above to ~/.ssh/authorized_keys — needs "
						+ "Remote Login enabled on this Mac.")
				}
		case .approved:
			LabeledContent("Guest → Mac") {
				Text("approved").foregroundStyle(MachmanColors.connected)
			}
			Button("Revoke Guest Access…", role: .destructive) { revokeConsent = true }
				.confirmationDialog(
					"Revoke \(vm.name)'s access?", isPresented: $revokeConsent
				) {
					Button("Revoke", role: .destructive) {
						viewModel.setSSHReverseApproved(vm.name, approved: false)
					}
					Button("Cancel", role: .cancel) {}
				} message: {
					Text("Removes exactly this VM's key line from ~/.ssh/authorized_keys.")
				}
		case .none, .unknown:
			Text("Two-way SSH: run the setup script with --two-way in the guest, then "
				+ "approve it here.")
				.font(.caption2)
				.foregroundStyle(.tertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

struct SSHInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@State private var showGuide = false
	@State private var resetConfirm = false

	private var macGuest: Bool { vm.boot.mode == .macOS }
	private var device: DeviceInfo? {
		(vm.devices ?? []).first { $0.kind == .sshInstaller }
	}

	var body: some View {
		Form {
			// Reachability and switches first — what someone opening this is usually
			// after; the setup half is below it.
			NetworkSSHSection(viewModel: viewModel, vm: vm)
			// Inspector text rule: nothing longer than one sentence — details live in
			// the Setup Guide sheet, never here.
			Section("Setup Script") {
				Text("Serves a script the guest runs once to enable SSH and exchange "
					+ "keys with this Mac.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				if let at = vm.ssh?.lastReportAt {
					LabeledContent("Last run") {
						HStack(spacing: 5) {
							if let status = vm.ssh?.lastRunStatus, status != "ok" {
								Image(systemName: MachmanSymbols.warning)
									.foregroundStyle(MachmanColors.warning)
								Text(status)
							}
							Text(at.formatted(date: .abbreviated, time: .shortened))
						}
					}
					// The script says what it could not finish; this is that sentence.
					if let note = vm.ssh?.lastRunNote,
						vm.ssh?.lastRunStatus != "ok" {
						Text(note)
							.font(.caption)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
					if let os = vm.ssh?.guestOS, let user = vm.ssh?.guestUser {
						let version = vm.ssh?.guestOSVersion.map { " \($0)" } ?? ""
						Text("\(user) on \(os)\(version)")
							.font(.system(.caption, design: .monospaced))
							.foregroundStyle(.secondary)
					}
					if vm.ssh?.sshfsAvailable != nil {
						LabeledContent("sshfs") { Text(sshfsSummary) }
					}
				} else {
					Text("No report yet — the guest hasn't run the script.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				if let identity = vm.ssh?.identityFilePath,
					let pub = try? String(contentsOfFile: identity + ".pub",
						encoding: .utf8) {
					LabeledContent("Public key") {
						CopyToClipboardButton(
							pub.trimmingCharacters(in: .whitespacesAndNewlines),
							tooltip: "Copy this Mac's public key")
					}
				}
			}
			Section("Guest Setup") {
				VStack(alignment: .leading, spacing: 6) {
					Text(macGuest
						? "Run in the guest's Terminal (the share automounts, macOS 13+):"
						: "Run in the guest (Linux; FreeBSD cannot mount the share — "
							+ "see the guide):")
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					CommandBlock(macGuest
						? SSHSetupInfo.runCommand : SSHSetupInfo.mountAndRunCommand)
					GuideButton(isPresented: $showGuide)
				}
			}
			Section {
				Button("Reset SSH State…", role: .destructive) { resetConfirm = true }
					.confirmationDialog("Reset SSH state?", isPresented: $resetConfirm) {
						Button("Reset", role: .destructive) { viewModel.resetSSH(vm.name) }
						Button("Cancel", role: .cancel) {}
					} message: {
						Text("Forgets this VM's keys, pinned identity, ~/.ssh entry, and "
							+ "approvals — the guest keeps what the script installed.")
					}
			}
			if let device {
				DeviceImplementationSection(vm: vm, device: device)
				DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .sshInstaller)
			}
		}
		.sheet(isPresented: $showGuide) {
			GuestSetupHelpSheet(vm: vm)
		}
	}

	// Mounting host folders needs sshfs in the guest AND the guest→Mac link it rides on,
	// so the capability is only usable once that access is approved.
	private var sshfsSummary: String {
		guard vm.ssh?.sshfsAvailable == true else { return "not installed" }
		if vm.ssh?.reverseState != .approved {
			return "available — needs guest → Mac approval"
		}
		if vm.ssh?.sshfsMountReady == false {
			return "available — mounts need root"
		}
		return "available"
	}
}
