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
	private var ownedKernels: [String] { vm.boot.ownedKernels ?? [] }
	private func isOwned(_ path: String) -> Bool { ownedKernels.contains(path) }

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

	// A store-name prompt (a subfolder under <vm>/kernels to avoid filename clashes).
	private func promptForName(suggestion: String) -> String? {
		let alert = NSAlert()
		alert.messageText = "Copy into the VM"
		alert.informativeText = "Name a subfolder under the VM's kernels directory."
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
		field.stringValue = suggestion
		alert.accessoryView = field
		alert.addButton(withTitle: "Copy")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return nil }
		let name = field.stringValue.trimmingCharacters(in: .whitespaces)
		return name.isEmpty ? nil : name
	}

	private func displayName(_ path: String) -> String {
		let base = (path as NSString).lastPathComponent
		if isOwned(path) {
			let store = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
			return "\(store)/\(base)"
		}
		return base
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

	@ViewBuilder
	private func fileRow(
		role: KernelRole, current: String, placeholder: String, browseTooltip: String,
		set: @escaping (String) -> Void
	) -> some View {
		let noun = role == .kernel ? "kernel" : "initramfs"
		HStack {
			Menu {
				ForEach(ownedKernels, id: \.self) { path in
					Button(displayName(path)) { set(path) }
				}
				if !ownedKernels.isEmpty { Divider() }
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

			if isOwned(current) {
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
			} else if !current.isEmpty {
				IconButton(
					symbol: MachmanSymbols.promoteDisk,
					tooltip: "Copy this \(noun) into the VM (take ownership)",
					flat: true
				) {
					if let name = promptForName(
						suggestion: (current as NSString).lastPathComponent) {
						viewModel.promoteKernel(
							vm.name, role: role, sourcePath: current, storeName: name)
					}
				}
			}
		}
	}
}

#Preview {
}
