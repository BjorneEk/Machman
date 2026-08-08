//
//  DefaultBootView.swift
//  Machman
//
//  Default boot editor: EFI by default, or direct Linux-kernel boot when the checkbox is on.
//  Field values live in the persisted kernel draft (BootInfo.kernel) so they survive toggling
//  back to EFI and app restarts.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct DefaultBootView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel
	@State private var kernelEnabled: Bool
	@State private var kernelPath: String
	@State private var initrdPath: String
	@State private var commandLine: String

	init(vm: VMInfo, viewModel: VMListViewModel) {
		self.vm = vm
		self.viewModel = viewModel
		_kernelEnabled = State(initialValue: vm.boot.mode == .linuxKernel)
		_kernelPath = State(initialValue: vm.boot.kernel?.kernelPath ?? "")
		_initrdPath = State(initialValue: vm.boot.kernel?.initrdPath ?? "")
		_commandLine = State(initialValue: vm.boot.kernel?.commandLine ?? "")
	}

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

	private func pickFile(_ assign: @escaping (String) -> Void) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.begin { response in
			if response == .OK, let url = panel.url {
				assign(url.path)
			}
		}
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
				HStack {
					Button(action: { pickFile { kernelPath = $0; pushSettings() } }) {
						Image(systemName: MachmanSymbols.browse)
							.font(.title2)
					}
					.help("Choose a kernel image (e.g. vmlinuz)")
					TextField("kernel image", text: $kernelPath)
						.textFieldStyle(.roundedBorder)
						.onSubmit { pushSettings() }
				}
				HStack {
					Button(action: { pickFile { initrdPath = $0; pushSettings() } }) {
						Image(systemName: MachmanSymbols.browse)
							.font(.title2)
					}
					.help("Choose an initial ramdisk (optional)")
					TextField("initramfs (optional)", text: $initrdPath)
						.textFieldStyle(.roundedBorder)
						.onSubmit { pushSettings() }
				}
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
}

#Preview {
}
