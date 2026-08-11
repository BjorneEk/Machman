//
//  DefaultBootView.swift
//  MachmanDesktop
//
//  Default boot editor: EFI by default, or direct Linux-kernel boot when the checkbox is on.
//  The kernel and initramfs are chosen from a dropdown of owned files (copies living in the VM)
//  plus Browse; each can be promoted (copied into the VM, becoming owned) or, once owned,
//  deleted — mirroring the disk import/promote model. The command line stays a free text field.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI

struct DefaultBootView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel
	@State private var kernelEnabled: Bool
	@State private var commandLine: String

	init(vm: VMInfo, viewModel: VMListViewModel) {
		self.vm = vm
		self.viewModel = viewModel
		_kernelEnabled = State(initialValue: vm.boot.mode == .linuxKernel)
		_commandLine = State(initialValue: vm.boot.kernel?.commandLine ?? "")
	}

	// Kernel/initramfs are server truth (dropdown-driven, no free typing), so read them from the
	// DTO — a promote/delete updates them via events without local state going stale.
	private var kernelPath: String { vm.boot.kernel?.kernelPath ?? "" }
	private var initrdPath: String { vm.boot.kernel?.initrdPath ?? "" }
	private var ownedKernels: [OwnedKernelFile] { vm.boot.ownedKernels ?? [] }
	private func owned(_ path: String) -> OwnedKernelFile? { ownedKernels.first { $0.path == path } }
	private func isOwned(_ path: String) -> Bool { owned(path) != nil }

	private var kernelMissing: Bool {
		kernelEnabled &&
			(kernelPath.isEmpty || !FileManager.default.fileExists(atPath: kernelPath))
	}

	private func pushSettings() {
		viewModel.updateKernelSettings(vm.name, KernelSettings(
			kernelPath: kernelPath,
			initrdPath: initrdPath.isEmpty ? nil : initrdPath,
			commandLine: commandLine))
	}

	private func setKernel(_ path: String) {
		viewModel.updateKernelSettings(vm.name, KernelSettings(
			kernelPath: path,
			initrdPath: initrdPath.isEmpty ? nil : initrdPath,
			commandLine: commandLine))
	}

	private func setInitrd(_ path: String) {
		viewModel.updateKernelSettings(vm.name, KernelSettings(
			kernelPath: kernelPath,
			initrdPath: path.isEmpty ? nil : path,
			commandLine: commandLine))
	}

	private func pickFile(_ assign: @escaping (String) -> Void) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.begin { response in
			if response == .OK, let url = panel.url { assign(url.path) }
		}
	}

	// Ask for a tag to label the copied file (a short name; grouped under it internally).
	private func promptForTag(role: KernelRole) -> String? {
		let noun = role == .kernel ? "kernel" : "initramfs"
		let alert = NSAlert()
		alert.messageText = "Copy into the VM"
		alert.informativeText = "A short tag to label this \(noun)."
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
		field.placeholderString = nextTag(role: role)
		alert.accessoryView = field
		alert.addButton(withTitle: "Copy")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return nil }
		let tag = field.stringValue.trimmingCharacters(in: .whitespaces)
		return tag.isEmpty ? nextTag(role: role) : tag
	}

	private func nextTag(role: KernelRole) -> String {
		let prefix = role == .kernel ? "kernel" : "initramfs"
		let used = Set(ownedKernels.filter { $0.role == role }.map(\.tag))
		var n = 1
		while used.contains("\(prefix)-\(n)") { n += 1 }
		return "\(prefix)-\(n)"
	}

	// Owned files show "<tag> - <file>"; external files show their filename.
	private func displayName(_ path: String) -> String {
		if let file = owned(path) { return "\(file.tag) - \(file.fileName)" }
		return (path as NSString).lastPathComponent
	}

	var body: some View {
		VStack {
			HStack {
				Image(systemName: MachmanSymbols.kernelBootToggle)
					.foregroundColor(.secondary)
				Toggle("Kernel boot", isOn: $kernelEnabled)
					.toggleStyle(.checkbox)
					.onChange(of: kernelEnabled) { _, newValue in
						pushSettings()
						Task {
							if await !viewModel.setKernelBoot(vm.name, enabled: newValue) {
								kernelEnabled = vm.boot.mode == .linuxKernel   // revert on refusal
							}
						}
					}
				Spacer()
				if kernelMissing {
					Text(kernelPath.isEmpty ? "kernel image required" : "kernel image not found")
						.foregroundColor(.red)
						.opacity(0.8)
				}
			}
			Divider()
			VStack {
				fileRow(
					role: .kernel, current: kernelPath, placeholder: "kernel image",
					browseTooltip: "Choose a kernel image (e.g. vmlinuz)", set: setKernel)
				fileRow(
					role: .initramfs, current: initrdPath, placeholder: "initramfs (optional)",
					browseTooltip: "Choose an initial ramdisk (optional)", set: setInitrd)
				HStack {
					Image(systemName: MachmanSymbols.kernelCommandLine)
						.font(.title2)
						.foregroundColor(.secondary)
					TextField("", text: $commandLine)
						.textFieldStyle(.roundedBorder)
						.onSubmit { pushSettings() }
						.placeholder(when: commandLine.isEmpty) {
							Text("console=hvc0 root=/dev/vda1 rw")
								.padding(.horizontal)
								.foregroundColor(.secondary)
						}
				}
			}
			.disabled(!kernelEnabled)
			.opacity(kernelEnabled ? 1 : 0.55)
		}
		.padding(4)
	}

	private func fileRow(
		role: KernelRole, current: String, placeholder: String, browseTooltip: String,
		set: @escaping (String) -> Void
	) -> some View {
		let noun = role == .kernel ? "kernel" : "initramfs"
		let roleOwned = ownedKernels.filter { $0.role == role }
		return HStack {
			Menu {
				ForEach(roleOwned) { file in
					Button("\(file.tag) - \(file.fileName)") { set(file.path) }
				}
				if !roleOwned.isEmpty { Divider() }
				Button("Browse…") { pickFile { set($0) } }
				if !current.isEmpty {
					Divider()
					Button("Clear") { set("") }
				}
			} label: {
				Text(current.isEmpty ? placeholder : displayName(current))
					.foregroundColor(current.isEmpty ? .secondary : .primary)
					.lineLimit(1).truncationMode(.middle)
			}
			.help(current.isEmpty ? browseTooltip : current)

			if current.isEmpty {
				// Nothing to promote/delete yet — an info hint on what to pick.
				Image(systemName: MachmanSymbols.info)
					.foregroundColor(.secondary)
					.help("Pick an owned \(noun) from the menu, or Browse to a file and then "
						+ "copy it into the VM.")
			} else if isOwned(current) {
				IconButton(
					symbol: MachmanSymbols.delete,
					tooltip: "Delete this owned \(noun) (removes the copied file)",
					flat: true, role: .destructive
				) {
					guard VMListViewModel.confirmDialog(
						message: "Delete owned \(noun)?",
						informativeText: "Removes \(displayName(current)) from the VM directory.")
					else { return }
					viewModel.deleteKernel(vm.name, path: current)
				}
			} else {
				IconButton(
					symbol: MachmanSymbols.promoteDisk,
					tooltip: "Copy this \(noun) into the VM (take ownership)",
					flat: true
				) {
					if let tag = promptForTag(role: role) {
						viewModel.promoteKernel(vm.name, role: role, sourcePath: current, tag: tag)
					}
				}
			}
		}
	}
}

#Preview {
}
