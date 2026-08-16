//
//  DeviceInspectors.swift
//  MachmanDesktop
//
//  Inspectors for the guest devices (1.0.4 UI): graphics, network, clipboard, and Rosetta
//  carry settings (riding vm.device.update); every other kind gets DeviceInfoInspector —
//  what the device IS (Mac/Generic variant + the VZ class, for a docs lookup) and Remove.
//

import SwiftUI
import AppKit
import CryptoKit
import MachmanUI
import MachmanAPI

// Router for the device kinds: dedicated inspectors where there are settings, the generic
// info inspector everywhere else.
struct DeviceInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let kind: DeviceKind

	var body: some View {
		if let device = vm.devices?.first(where: { $0.kind == kind }) {
			switch device.kind {
			case .graphics:
				GraphicsInspector(viewModel: viewModel, vm: vm, device: device)
			case .network:
				NetworkInspector(viewModel: viewModel, vm: vm, device: device)
			case .clipboard:
				ClipboardInspector(viewModel: viewModel, vm: vm, device: device)
			case .rosetta:
				RosettaInspector(viewModel: viewModel, vm: vm, device: device)
			case .consoleLoginInstaller:
				LoginInstallerInspector(viewModel: viewModel, vm: vm, device: device)
			case .sshInstaller:
				SSHSetupInspector(viewModel: viewModel, vm: vm, device: device)
			case .unknown:
				NoSelectionInspector()
			default:
				DeviceInfoInspector(viewModel: viewModel, vm: vm, device: device)
			}
		} else {
			NoSelectionInspector()
		}
	}
}

// The generic inspector for kinds without settings: the host gate if any, what the device
// is, and Remove — selecting a keyboard is no longer a dead end.
struct DeviceInfoInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo

	var body: some View {
		Form {
			if let gate = device.unavailable {
				Section {
					Label {
						VStack(alignment: .leading, spacing: 3) {
							Text("Unavailable on this host")
								.fontWeight(.medium)
							Text(gate.message)
								.font(.caption)
								.foregroundStyle(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
					} icon: {
						Image(systemName: MachmanSymbols.warning)
							.foregroundStyle(MachmanColors.warning)
					}
				}
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: device.kind)
		}
	}
}

// Shared "what IS this device" section: the Mac/Generic variant where it's meaningful and
// the VZ class the engine instantiates, copyable for a docs lookup. Sits directly above the
// remove row in every device inspector.
private struct DeviceImplementationSection: View {
	let vm: VMInfo
	let device: DeviceInfo

	private var macGuest: Bool { vm.boot.mode == .macOS }

	var body: some View {
		Section("Implementation") {
			if let variant = device.kind.variantLabel(macGuest: macGuest) {
				LabeledContent("Variant", value: variant)
			}
			if let className = device.kind.vzClassName(macGuest: macGuest) {
				LabeledContent("Class") {
					HStack(spacing: 4) {
						Text(className)
							.font(.system(.caption, design: .monospaced))
							.textSelection(.enabled)
							.lineLimit(1)
							.truncationMode(.middle)
							.help(className)
						CopyToClipboardButton(className, tooltip: "Copy class name")
					}
				}
			}
			Text(caption)
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var caption: String {
		var text = "The Virtualization framework class this device instantiates — "
			+ "searchable in Apple's developer documentation."
		switch device.kind {
		case .keyboard, .graphics:
			text += " Chosen by the VM's boot mode: macOS guests get the Mac device, EFI "
				+ "and kernel boots the generic one."
		case .clipboard:
			text += " The sharing itself is a spice agent port (VZSpiceAgentPortAttachment) "
				+ "on this console device."
		default:
			break
		}
		return text
	}
}

// Shared trailing row: remove the device (next-boot effect, like every device change).
private struct DeviceRemoveRow: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let kind: DeviceKind

	var body: some View {
		Section {
			HStack {
				IconButton(
					symbol: MachmanSymbols.delete,
					tooltip: "Remove \(kind.displayLabel)"
				) {
					viewModel.removeDevice(vm.name, kind: kind)
				}
				Spacer()
			}
		}
	}
}

// MARK: - Graphics ----------------------------------------------------------------------------

// Display size as a resolution selector (design): Auto (host-sized at start), the common
// resolutions plus the actual host display, or Custom — which reveals the width/height
// fields. Bounds mirror the daemon's validation (640…8192 px, 40…300 ppi).
struct GraphicsInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo
	@State private var customMode = false
	@State private var customWidth = 1920
	@State private var customHeight = 1080

	private enum Resolution: Hashable {
		case auto
		case preset(Int, Int)
		case custom
	}

	private var commonPresets: [(Int, Int)] {
		var presets: [(Int, Int)] = []
		if let w = viewModel.capabilities?.hostDisplayWidthPixels,
			let h = viewModel.capabilities?.hostDisplayHeightPixels {
			presets.append((w, h))
		}
		for p in [(1280, 800), (1920, 1080), (2560, 1440), (2560, 1600),
			(3024, 1964), (3456, 2234), (3840, 2160)]
			where !presets.contains(where: { $0 == p }) {
			presets.append(p)
		}
		return presets
	}

	private var currentResolution: Resolution {
		if customMode { return .custom }
		guard let w = device.displayWidthPixels, let h = device.displayHeightPixels else {
			return .auto
		}
		return commonPresets.contains(where: { $0 == (w, h) }) ? .preset(w, h) : .custom
	}

	var body: some View {
		Form {
			Section("Display") {
				Picker("Resolution", selection: resolutionBinding) {
					Text("Auto (host screen)").tag(Resolution.auto)
					ForEach(commonPresets, id: \.0) { w, h in
						Text(presetLabel(w, h)).tag(Resolution.preset(w, h))
					}
					Text("Custom…").tag(Resolution.custom)
				}
				if currentResolution == .custom {
					LabeledContent("Width") {
						TextField("", value: $customWidth, format: .number)
							.textFieldStyle(.plain)
							.multilineTextAlignment(.trailing)
							.frame(width: 70)
							.onSubmit { commitCustom() }
					}
					LabeledContent("Height") {
						TextField("", value: $customHeight, format: .number)
							.textFieldStyle(.plain)
							.multilineTextAlignment(.trailing)
							.frame(width: 70)
							.onSubmit { commitCustom() }
					}
				}
				if vm.boot.mode == .macOS {
					LabeledContent("Pixels per inch") {
						TextField("80", value: ppiBinding, format: .number)
							.textFieldStyle(.plain)
							.multilineTextAlignment(.trailing)
							.frame(width: 70)
					}
				}
				Text("Auto sizes from the host screen at start. Changes apply at the "
					+ "next boot.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .graphics)
		}
		.onAppear { seedCustomFields() }
	}

	private func presetLabel(_ w: Int, _ h: Int) -> String {
		let host = viewModel.capabilities?.hostDisplayWidthPixels == w
			&& viewModel.capabilities?.hostDisplayHeightPixels == h
		return host ? "Host display (\(w) × \(h))" : "\(w) × \(h)"
	}

	private var resolutionBinding: Binding<Resolution> {
		Binding(
			get: { currentResolution },
			set: { choice in
				switch choice {
				case .auto:
					customMode = false
					commit(width: nil, height: nil)
				case .preset(let w, let h):
					customMode = false
					commit(width: w, height: h)
				case .custom:
					seedCustomFields()
					customMode = true   // fields appear; commit happens on submit
				}
			})
	}

	private func seedCustomFields() {
		customWidth = device.displayWidthPixels
			?? viewModel.capabilities?.hostDisplayWidthPixels ?? 1920
		customHeight = device.displayHeightPixels
			?? viewModel.capabilities?.hostDisplayHeightPixels ?? 1080
	}

	private func commitCustom() {
		customWidth = max(640, min(8192, customWidth))
		customHeight = max(640, min(8192, customHeight))
		commit(width: customWidth, height: customHeight)
	}

	private func commit(width: Int?, height: Int?) {
		var updated = device
		updated.displayWidthPixels = width
		updated.displayHeightPixels = height
		viewModel.updateDevice(vm.name, device: updated)
	}

	private var ppiBinding: Binding<Int?> {
		Binding(
			get: { device.displayPixelsPerInch },
			set: { value in
				var updated = device
				updated.displayPixelsPerInch = value.map { max(40, min(300, $0)) }
				viewModel.updateDevice(vm.name, device: updated)
			})
	}
}

// MARK: - Network -----------------------------------------------------------------------------

// The MAC address's ONLY home (per the design): shown, copyable, regenerable while stopped.
struct NetworkInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo
	@State private var regenConfirm = false

	var body: some View {
		Form {
			Section("Network") {
				LabeledContent("Attachment", value: "NAT")
					.help("Bridged networking is a future attachment kind")
				LabeledContent("MAC") {
					HStack(spacing: 4) {
						Text(vm.macAddress ?? "— (assigned on first boot)")
							.font(.system(.callout, design: .monospaced))
							.foregroundStyle(vm.macAddress == nil ? .secondary : .primary)
						if let mac = vm.macAddress {
							CopyToClipboardButton(mac, tooltip: "Copy MAC address")
							IconButton(
								symbol: MachmanSymbols.regenerate,
								tooltip: vm.state.isRunning
									? "Stop the VM to change its MAC address"
									: "New MAC address (guest sees it on next boot)",
								font: .callout, flat: true
							) {
								regenConfirm = true
							}
							.disabled(vm.state.isRunning)
						}
					}
				}
			}
			NetworkAddressSection(viewModel: viewModel, vm: vm)
			NetworkSSHSection(viewModel: viewModel, vm: vm)
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .network)
		}
		.confirmationDialog("Regenerate MAC address?", isPresented: $regenConfirm) {
			Button("Regenerate") { viewModel.regenerateMAC(vm.name) }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("\(vm.name) gets a new random MAC. DHCP leases and MAC-based network "
				+ "rules tied to the old address will stop matching.")
		}
	}
}

// MARK: - Clipboard ---------------------------------------------------------------------------

// The spice-agent console port (EFI/kernel guests): whether the pasteboard is shared.
struct ClipboardInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo

	var body: some View {
		Form {
			Section("Clipboard Sharing") {
				Toggle("Share clipboard with guest", isOn: Binding(
					get: { device.sharesClipboard ?? true },
					set: { value in
						var updated = device
						updated.sharesClipboard = value
						viewModel.updateDevice(vm.name, device: updated)
					}))
				Text("Spice agent port — Linux/EFI guests only (macOS guests don't "
					+ "support it). The guest needs spice-vdagent running. Applies at "
					+ "the next boot.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .clipboard)
		}
	}
}

// MARK: - Rosetta -----------------------------------------------------------------------------

// Host availability from capabilities (host.installRosetta flips it), the fixed mount tag,
// and the guest binfmt setup.
struct RosettaInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo

	private var availability: String? { viewModel.capabilities?.rosettaAvailability }

	var body: some View {
		Form {
			Section("Rosetta x86-64") {
				LabeledContent("Status") {
					switch availability {
					case RosettaAvailability.installed:
						Label("Installed", systemImage: MachmanSymbols.activeEntry)
							.foregroundStyle(MachmanColors.stateRunning)
					case RosettaAvailability.notInstalled:
						Label("Not installed", systemImage: MachmanSymbols.warning)
							.foregroundStyle(MachmanColors.warning)
					case RosettaAvailability.notSupported:
						Label("Not supported on this host",
							systemImage: MachmanSymbols.warning)
							.foregroundStyle(MachmanColors.warning)
					default:
						Text("Unknown").foregroundStyle(.secondary)
					}
				}
				if availability == RosettaAvailability.notInstalled {
					Button("Install Rosetta Support…") {
						viewModel.installRosetta()
					}
					.help("macOS prompts for the download; the VM's share attaches on "
						+ "the next boot once installed")
				}
				if let gate = device.unavailable {
					Text(gate.message)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				LabeledContent("Mount tag", value: "rosetta")
			}
			Section("Guest Setup") {
				VStack(alignment: .leading, spacing: 6) {
					Text("Mount the share, then register the binfmt handler:")
						.font(.caption)
						.foregroundStyle(.secondary)
					HStack {
						Text(Self.setupCommand)
							.font(.system(.caption, design: .monospaced))
							.textSelection(.enabled)
						Spacer()
						CopyToClipboardButton(Self.setupCommand, tooltip: "Copy commands")
					}
					.padding(6)
					.background(RoundedRectangle(cornerRadius: 5)
						.fill(Color.primary.opacity(0.05)))
					Text("Lets Linux guests run x86-64 binaries through Rosetta.")
						.font(.caption)
						.foregroundStyle(.tertiary)
				}
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .rosetta)
		}
	}

	private static let setupCommand = "mount -t virtiofs rosetta /media/rosetta\n"
		+ "/media/rosetta/rosetta must be registered with binfmt_misc "
		+ "(see Apple's VZLinuxRosettaDirectoryShare docs)"
}

// MARK: - Console Login ----------------------------------------------------------------------

// The macOS-guest console login installer: a read-only folder (a generated install script)
// automounting in the guest; one command installs a login prompt per console.
struct LoginInstallerInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo
	@State private var showGuide = false

	// The enabled consoles' guest device names — what the script will cover.
	private var consoleNames: [String] {
		let count = (vm.consolePorts ?? []).filter(\.isEnabled).count
		return (0..<count).map {
			SerialPortKind.console.guestDevice(index: $0, os: .macOS)
		}
	}

	private static let guestCommand = ConsoleLoginInstallerInfo.runCommand

	var body: some View {
		Form {
			if let gate = device.unavailable {
				Section {
					Label {
						VStack(alignment: .leading, spacing: 3) {
							Text("Unavailable on this host")
								.fontWeight(.medium)
							Text(gate.message)
								.font(.caption)
								.foregroundStyle(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
					} icon: {
						Image(systemName: MachmanSymbols.warning)
							.foregroundStyle(MachmanColors.warning)
					}
				}
			}
			Section("Console Login") {
				Text("A read-only “\(ConsoleLoginInstallerInfo.directoryName)” folder in "
					+ "the guest's automounting “My Shared Files” volume (next to this "
					+ "VM's mounts), carrying an install script that sets up a login "
					+ "prompt on every console.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				LabeledContent("Consoles covered") {
					Text(consoleNames.isEmpty
						? "none" : consoleNames.joined(separator: ", "))
						.font(.system(.callout, design: .monospaced))
				}
				if consoleNames.isEmpty {
					Text("Add a console first — the script has nothing to set up "
						+ "without one.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Section("Guest Setup") {
				VStack(alignment: .leading, spacing: 6) {
					Text("Boot the guest (the share appears on its own, macOS 13+), then "
						+ "run in its Terminal:")
						.font(.caption)
						.foregroundStyle(.secondary)
					HStack {
						Text(Self.guestCommand)
							.font(.system(.caption, design: .monospaced))
							.textSelection(.enabled)
							.fixedSize(horizontal: false, vertical: true)
						Spacer()
						CopyToClipboardButton(Self.guestCommand, tooltip: "Copy command")
					}
					.padding(6)
					.background(RoundedRectangle(cornerRadius: 5)
						.fill(Color.primary.opacity(0.05)))
					Text("Installs one login daemon per console — prompts appear "
						+ "immediately. Re-run it after adding or removing consoles (it "
						+ "cleans up removed ones); --uninstall removes the logins. "
						+ "Afterwards this installer can be disabled or removed — the "
						+ "logins persist in the guest.")
						.font(.caption)
						.foregroundStyle(.tertiary)
						.fixedSize(horizontal: false, vertical: true)
					Text("Volume missing (macOS 12 guests)? "
						+ "\(ConsoleLoginInstallerInfo.fallbackMountCommand)")
						.font(.system(.caption2, design: .monospaced))
						.foregroundStyle(.tertiary)
						.fixedSize(horizontal: false, vertical: true)
					Button {
						showGuide = true
					} label: {
						Label("Setup Guide…", systemImage: MachmanSymbols.help)
					}
				}
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .consoleLoginInstaller)
		}
		.sheet(isPresented: $showGuide) {
			ConsoleHelpSheet(mode: .macOS, guestIndex: 0)
		}
	}
}

// MARK: - SSH Setup ------------------------------------------------------------------------------

// OpenSSH-style fingerprint of a public-key line ("SHA256:…") for approval dialogs.
private func sshKeyFingerprint(_ keyLine: String) -> String? {
	let fields = keyLine.split(separator: " ")
	guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
		return nil
	}
	let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
	return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
}

// The guest's discovered address — a fact of the running VM (leases/ARP by its MAC),
// not of SSH, so it shows for every VM whether or not SSH is set up.
private struct NetworkAddressSection: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	var body: some View {
		Section("Guest Address") {
			LabeledContent("IP") {
				HStack(spacing: 4) {
					if let address = vm.ssh?.address {
						Text(address)
							.font(.system(.callout, design: .monospaced))
						CopyToClipboardButton(address, tooltip: "Copy address")
					} else {
						Text(vm.state.isRunning ? "discovering…" : "— (start the VM)")
							.foregroundStyle(.secondary)
					}
					if vm.state.isRunning {
						IconButton(symbol: MachmanSymbols.regenerate,
							tooltip: "Re-run address discovery", font: .callout,
							flat: true) {
							viewModel.refreshSSH(vm.name)
						}
					}
				}
			}
			if let source = vm.ssh?.addressSource {
				Text(source == "dhcp" ? "via the host's DHCP leases" : "via the ARP table")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
	}
}

// The SSH half of the network inspector — status and switches; the address itself lives
// in NetworkAddressSection above (it needs no SSH). Switches are consent-gated.
private struct NetworkSSHSection: View {
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
			HStack {
				Text(command)
					.font(.system(.caption, design: .monospaced))
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
				Spacer()
				CopyToClipboardButton(command, tooltip: "Copy command")
			}
			.padding(6)
			.background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
		}
		integrationToggle
		aliasField
		reverseRows
	}

	// The name this VM answers to — in ~/.ssh and in the session tabs' host-key pin.
	private var aliasField: some View {
		VStack(alignment: .leading, spacing: 2) {
			LabeledContent("Alias") {
				TextField("\(vm.name).machman", text: $aliasDraft)
					.multilineTextAlignment(.trailing)
					.onSubmit { viewModel.setSSHAlias(vm.name, alias: aliasDraft) }
			}
			if !aliasDraft.contains(".") && !aliasDraft.isEmpty {
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
			Button("Approve Guest Access…") { approveConsent = true }
				.confirmationDialog(
					"Let \(vm.name) log in to this Mac as you?", isPresented: $approveConsent
				) {
					Button("Approve") {
						viewModel.setSSHReverseApproved(vm.name, approved: true)
					}
					Button("Cancel", role: .cancel) {}
				} message: {
					Text("Adds the key shown in the inspector to ~/.ssh/authorized_keys — "
						+ "needs Remote Login enabled on this Mac.")
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

// The SSH Setup installer's own inspector: what it serves, how to run it per guest OS,
// report status, and the deeper reset.
struct SSHSetupInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo
	@State private var showGuide = false
	@State private var resetConfirm = false

	private var macGuest: Bool { vm.boot.mode == .macOS }

	var body: some View {
		Form {
			// Inspector text rule: nothing longer than one sentence — details live in
			// the Setup Guide sheet, never here.
			Section("SSH Setup") {
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
					commandBlock(macGuest
						? SSHSetupInfo.runCommand : SSHSetupInfo.mountAndRunCommand)
					Button {
						showGuide = true
					} label: {
						Label("Setup Guide…", systemImage: MachmanSymbols.help)
					}
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
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .sshInstaller)
		}
		.sheet(isPresented: $showGuide) {
			SSHHelpSheet(vm: vm)
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

	private func commandBlock(_ command: String) -> some View {
		HStack {
			Text(command)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			Spacer()
			CopyToClipboardButton(command, tooltip: "Copy command")
		}
		.padding(6)
		.background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
	}
}
