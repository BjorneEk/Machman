//
//  SSHInspector.swift
//  MachmanDesktopUI
//
//  EVERYTHING SSH for one VM, in one place: the tree's SSH section opens it. It used to be
//  spread across the network device (status, alias, guest access) and the installer device
//  (payload, guide, reset), which meant reading two inspectors to answer one question. The
//  installer itself has its own inspector (GuestSetupInspector.swift).
//

import SwiftUI
import CryptoKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

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
	// Seeds the alias field with an unsent draft instead of the alias (render scenes).
	var initialAliasDraft: String? = nil

	private var setupAttached: Bool {
		(vm.devices ?? []).contains { $0.kind == .guestSetup }
	}
	// Served, never derived: the VM can be named something else in ~/.ssh. The fallback
	// (an older daemon) follows the daemon's own mapping.
	private var alias: String { vm.ssh?.alias ?? SSHAliasRule.defaultAlias(for: vm.name) }
	private var sshCommand: String? {
		guard let ssh = vm.ssh else { return nil }
		if ssh.integrationEnabled == true {
			return "ssh \"\(alias)\""
		}
		// Self-contained command — works without the ~/.ssh integration.
		return SSHCommand.shellLine(for: vm)
	}

	var body: some View {
		Section("SSH") {
			if vm.ssh == nil && !setupAttached {
				Text("Add the Guest Setup installer to reach this VM over SSH — its "
					+ "script enables sshd and exchanges keys with this Mac.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Button("Add Guest Setup") {
					viewModel.addDevice(vm.name, kind: .guestSetup)
				}
			} else {
				statusRows
			}
		}
	}

	@ViewBuilder
	private var statusRows: some View {
		LabeledContent("Guest user") {
			Text(vm.ssh?.guestUser ?? "— run Guest Setup in the guest")
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
	// Every inspector rename works alike (PR8): Return renames, a problem shows under the
	// field while it is typed, and nothing else is said.
	private var aliasField: some View {
		VStack(alignment: .leading, spacing: 3) {
			TextField("Alias", text: $aliasDraft)
				.onSubmit { viewModel.submitSSHAlias(vm, draft: aliasDraft) }
			if aliasDraft != alias {
				if let problem = viewModel.sshAliasProblem(aliasDraft, for: vm) {
					FieldProblem(problem)
				}
			} else if !aliasDraft.contains(".") && !aliasDraft.isEmpty {
				Text("A plain name can shadow a real host in your SSH config.")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
		.servedDraft($aliasDraft, of: alias, seed: initialAliasDraft)
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
			"Add “\(alias)” to your SSH config?", isPresented: $integrationConsent
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
				Text("Awaiting your approval").foregroundStyle(.secondary)
			}
			fingerprintRow
			HStack {
				approveButton
				// An answer, not a postponement: denying stops the asking until the guest
				// reports a different key.
				Button("Deny") { viewModel.setSSHReverseApproved(vm.name, approved: false) }
			}
		case .denied:
			LabeledContent("Guest → Mac") {
				Text("Denied").foregroundStyle(.secondary)
			}
			// A denied key stays served, so a later approval still shows what it adds.
			fingerprintRow
			approveButton
		case .approved:
			LabeledContent("Guest → Mac") {
				Text("Approved").foregroundStyle(MachmanColors.connected)
			}
			Button("Revoke Guest Access…", role: .destructive) { revokeConsent = true }
				.confirmationDialog(
					"Revoke guest access for “\(vm.name)”?", isPresented: $revokeConsent
				) {
					Button("Revoke", role: .destructive) {
						viewModel.setSSHReverseApproved(vm.name, approved: false)
					}
					Button("Cancel", role: .cancel) {}
				} message: {
					Text("Removes exactly this VM’s key line from ~/.ssh/authorized_keys.")
				}
		case .none, .unknown:
			Text("For guest → Mac SSH, run Guest Setup with --two-way, then approve the key "
				+ "here.")
				.font(.caption2)
				.foregroundStyle(.tertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	// The guest's key, as the approval dialog's "key shown above".
	@ViewBuilder
	private var fingerprintRow: some View {
		if let fingerprint = vm.ssh?.reversePublicKey.flatMap(sshKeyFingerprint) {
			Text(fingerprint)
				.font(.system(.caption2, design: .monospaced))
				.foregroundStyle(.tertiary)
				.textSelection(.enabled)
		}
	}

	private var approveButton: some View {
		Button("Approve…") { approveConsent = true }
			.confirmationDialog(
				"Let “\(vm.name)” log in to this Mac as you?", isPresented: $approveConsent
			) {
				Button("Approve") {
					viewModel.setSSHReverseApproved(vm.name, approved: true)
				}
				Button("Cancel", role: .cancel) {}
			} message: {
				Text("Adds the key shown above to ~/.ssh/authorized_keys — needs "
					+ "Remote Login enabled on this Mac.")
			}
	}
}

// The SSH half only (1.0.7): switches, keys and access. The installer, its status and
// its run commands live in the Guest Setup inspector — this one never mentions them
// beyond the pointer shown while nothing is set up yet.
struct SSHInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	private let aliasDraft: String?
	@State private var resetConfirm = false

	// `aliasDraft` opens the alias field on an unsent draft (render scenes).
	init(viewModel: VMListViewModel, vm: VMInfo, aliasDraft: String? = nil) {
		self.viewModel = viewModel
		self.vm = vm
		self.aliasDraft = aliasDraft
	}

	var body: some View {
		Form {
			NetworkSSHSection(viewModel: viewModel, vm: vm, initialAliasDraft: aliasDraft)
			Section("Keys") {
				if let identity = vm.ssh?.identityFilePath,
					let pub = try? String(contentsOfFile: identity + ".pub",
						encoding: .utf8) {
					LabeledContent("Public key") {
						CopyToClipboardButton(
							pub.trimmingCharacters(in: .whitespacesAndNewlines),
							tooltip: "Copy this Mac’s public key")
					}
				}
				if vm.ssh?.sshfsAvailable != nil {
					LabeledContent("sshfs") { Text(sshfsSummary) }
				}
			}
			Section {
				Button("Reset SSH State…", role: .destructive) { resetConfirm = true }
					.confirmationDialog("Reset SSH state?", isPresented: $resetConfirm) {
						Button("Reset", role: .destructive) { viewModel.resetSSH(vm.name) }
						Button("Cancel", role: .cancel) {}
					} message: {
						Text("Forgets this VM’s keys, pinned identity, ~/.ssh entry, and "
							+ "approvals — the guest keeps what the script installed.")
					}
			}
		}
	}

	// Mounting host folders needs sshfs in the guest AND the guest→Mac link it rides on,
	// so the capability is only usable once that access is approved.
	private var sshfsSummary: String {
		guard vm.ssh?.sshfsAvailable == true else { return "Not installed" }
		if vm.ssh?.reverseState != .approved {
			return "Available — needs guest → Mac approval"
		}
		if vm.ssh?.sshfsMountReady == false {
			return "Available — mounts need root"
		}
		return "Available"
	}
}
