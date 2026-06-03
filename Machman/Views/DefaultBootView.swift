//
//  DefaultBootView.swift
//  Machman
//
//  Default boot editor: EFI by default, or direct Linux-kernel boot when the checkbox is on.
//  Field values live in VMConfig.kernelSettings (a persisted draft) so they survive toggling
//  back to EFI and app restarts.
//

import SwiftUI

struct DefaultBootView: View {
	@State private var vm: VirtualMachine
	@State private var kernelEnabled: Bool
	@State private var kernelPath: String
	@State private var initrdPath: String
	@State private var commandLine: String

	init(vm: VirtualMachine) {
		self.vm = vm
		kernelEnabled = vm.config.isKernelBoot
		kernelPath = vm.config.kernelSettings?.kernelPath ?? ""
		initrdPath = vm.config.kernelSettings?.initialRamdiskPath ?? ""
		commandLine = vm.config.kernelSettings?.commandLine ?? ""
	}

	private var kernelMissing: Bool {
		kernelEnabled &&
			(kernelPath.isEmpty || !FileManager.default.fileExists(atPath: kernelPath))
	}

	private func pushSettings() {
		let settings = LinuxKernelBoot(
			kernelPath: kernelPath,
			initialRamdiskPath: initrdPath.isEmpty ? nil : initrdPath,
			commandLine: commandLine)
		do {
			try vm.config.updateKernelSettings(settings)
		} catch {
			vm.log(error: "Failed to save kernel settings: \(error.localizedDescription)")
		}
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
				Image(systemName: "bolt.fill")
					.foregroundColor(.secondary)
				Toggle("Kernel boot", isOn: $kernelEnabled)
					.toggleStyle(.checkbox)
					.onChange(of: kernelEnabled) { _, newValue in
						pushSettings()
						do {
							try vm.config.setKernelBoot(enabled: newValue)
						} catch {
							kernelEnabled = vm.config.isKernelBoot   // revert on refusal
							vm.log(error: "Failed to switch boot mode: \(error.localizedDescription)")
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
						Image(systemName: "folder.fill.badge.plus")
							.font(.title2)
					}
					.help("Choose a kernel image (e.g. vmlinuz)")
					TextField("kernel image", text: $kernelPath)
						.textFieldStyle(.roundedBorder)
						.onSubmit { pushSettings() }
				}
				HStack {
					Button(action: { pickFile { initrdPath = $0; pushSettings() } }) {
						Image(systemName: "folder.fill.badge.plus")
							.font(.title2)
					}
					.help("Choose an initial ramdisk (optional)")
					TextField("initramfs (optional)", text: $initrdPath)
						.textFieldStyle(.roundedBorder)
						.onSubmit { pushSettings() }
				}
				HStack {
					Image(systemName: "terminal.fill")
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
