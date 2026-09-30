//
//  InspectorView.swift
//  MachmanDesktop
//
//  The right-hand inspector (1.0.4 UI): per-selection grouped forms driven by the sidebar
//  tree's selection. This file holds the router + the VM inspector; entity inspectors live
//  in their own files, and unrouted selections fall back to a quiet placeholder.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct InspectorView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var profiles: TerminalProfileStore
	let vm: VMInfo

	var body: some View {
		Group {
			if viewModel.treeSelection.count > 1 {
				MultiSelectionInspector(viewModel: viewModel, vm: vm)
			} else {
				switch viewModel.treeSelection.first {
				case .group("Kernel"):
					KernelParentInspector(viewModel: viewModel, vm: vm)
				case .group("SSH"):
					SSHInspector(viewModel: viewModel, vm: vm)
				case .group("Serial"):
					SerialGroupInspector(viewModel: viewModel, vm: vm)
				case .kernel(let path):
					KernelEntryInspector(viewModel: viewModel, vm: vm, path: path)
				case .initramfs(let path):
					InitramfsEntryInspector(viewModel: viewModel, vm: vm, path: path)
				case .vmRoot, nil, .group:
					VMInspector(viewModel: viewModel, profiles: profiles, vm: vm)
				case .sshSession(let ref):
					SSHSessionInspector(
						viewModel: viewModel, sessions: viewModel.terminals,
						profiles: profiles, vm: vm, ref: ref)
				case .disk(let id):
					DiskInspector(viewModel: viewModel, vm: vm, diskID: id)
				case .mount(let id):
					MountInspector(viewModel: viewModel, vm: vm, mountID: id)
				case .serial(let ref):
					SerialInspector(
						vm: vm, ref: ref, viewModel: viewModel, sessions: sessions,
						profiles: profiles)
				case .device(let kind):
					DeviceInspector(viewModel: viewModel, vm: vm, kind: kind)
				}
			}
		}
		.formStyle(.grouped)
	}
}

struct NoSelectionInspector: View {
	var body: some View {
		VStack(spacing: 8) {
			Image(systemName: MachmanSymbols.infoPanel)
				.font(.system(size: 26))
				.foregroundStyle(.tertiary)
			Text("No details for this selection")
				.font(.callout)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

// Batch actions over a multi-selection: enable/disable everything that has the flag.
struct MultiSelectionInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	var body: some View {
		Form {
			Section("\(viewModel.treeSelection.count) Items Selected") {
				Button("Enable All") { setAll(true) }
				Button("Disable All") { setAll(false) }
			}
		}
	}

	private func setAll(_ enabled: Bool) {
		viewModel.setSelectionEnabled(enabled, vm: vm)
	}
}

// MARK: - VM ----------------------------------------------------------------------------------

struct VMInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let profiles: TerminalProfileStore
	let vm: VMInfo
	@State private var draftName = ""
	@State private var memText = ""
	@State private var macSwitchSheet = false

	// macOS guests carry install-time hardware minimums; other modes have none.
	private var cpuFloor: Int { max(1, vm.boot.minCPUCount ?? 1) }
	private var memoryFloor: UInt64 { vm.boot.minMemoryBytes ?? 0 }
	private var cpuRange: ClosedRange<Int> {
		let upper = max(viewModel.capabilities?.maxCPUCount ?? cpuFloor, cpuFloor)
		return cpuFloor...upper
	}

	var body: some View {
		Form {
			Section("Machine") {
				TextField("Name", text: $draftName)
					.onSubmit {
						viewModel.requestRename(vm, to: draftName, profiles: profiles)
					}
					.onAppear { draftName = vm.name }
					.onChange(of: vm.name) { draftName = vm.name }
				LabeledContent {
					Stepper("\(vm.cpuCount) cores", value: cpuBinding, in: cpuRange)
				} label: {
					Label("CPUs", systemImage: MachmanSymbols.cpu)
				}
				LabeledContent {
					TextField("", text: $memText)
						.textFieldStyle(.plain)
						.multilineTextAlignment(.trailing)
						.frame(width: 90)
						.onChange(of: memText) {
							// Permissive while typing; interpretation happens on submit.
							let filtered = String(memText
								.filter { "0123456789.,kmgbKMGB ".contains($0) }.prefix(12))
							if filtered != memText { memText = filtered }
						}
						.onSubmit { commitMemory() }
						.help("\(vm.memoryBytes.formatted()) bytes")
				} label: {
					Label("Memory", systemImage: MachmanSymbols.memory)
				}
				.onAppear { memText = ByteSize.format(vm.memoryBytes) }
				.onChange(of: vm.memoryBytes) { memText = ByteSize.format(vm.memoryBytes) }
				// The MAC lives in the Network device's inspector (Devices → Network).
			}

			Section("Boot") {
				if vm.boot.macInstalled {
					LabeledContent("Bootloader") {
						HStack(spacing: 4) {
							Image(systemName: MachmanSymbols.bootMacTab)
							Text("macOS")
						}
					}
					.help("macOS is installed — the bootloader can no longer change")
				} else {
					Picker("Bootloader", selection: bootBinding) {
						Text("EFI").tag(BootInfo.Mode.efi)
						Text("Kernel boot").tag(BootInfo.Mode.linuxKernel)
						Text("macOS…").tag(BootInfo.Mode.macOS)
					}
					.disabled(viewModel.isInstalling(vm))
					// Already in macOS mode but not installed (mac template, failed
					// install): re-selecting macOS can't fire the picker, so the install
					// needs its own way in.
					if vm.boot.mode == .macOS && !viewModel.isInstalling(vm) {
						Button("Install macOS…") { macSwitchSheet = true }
					}
				}
				if vm.boot.mode != .macOS {
					Toggle("Allow nested virtualization", isOn: nestedBinding)
						.disabled(
							viewModel.capabilities?.nestedVirtualizationSupported == false)
						.help(viewModel.capabilities?.nestedVirtualizationSupported == false
							? "This host cannot expose virtualization extensions to guests"
							: "Exposes virtualization extensions to the guest (EFI/Linux)")
				}
			}

			Section("Default Start") {
				HStack(spacing: 6) {
					Toggle("Open window", isOn: policyBinding(\.windowed))
					if !vm.hasEnabledGraphics {
						Image(systemName: MachmanSymbols.warning)
							.font(.system(size: 11))
							.foregroundStyle(MachmanColors.warning)
							.help("No display device — the window can't open until one "
								+ "is added")
					}
				}
				Toggle("Safe mode", isOn: policyBinding(\.safe))
				Toggle("Autostart with daemon", isOn: policyBinding(\.autostart))
			}

			runtimeSection
		}
		.sheet(isPresented: $macSwitchSheet) {
			MacSwitchSheet(viewModel: viewModel, vm: vm)
		}
	}

	// Grounded in the wire: lastRan doubles as the start time while running (HistoryView's
	// rule); there is no separate startedAt.
	@ViewBuilder
	private var runtimeSection: some View {
		Section("Runtime") {
			LabeledContent("State") {
				HStack(spacing: 5) {
					StatusDot(state: vm.state, size: 7)
					Text(String(describing: vm.state))
				}
			}
			if vm.state.isRunning, let started = vm.lastRan {
				LabeledContent("Uptime") {
					TimelineView(.periodic(from: .now, by: 1)) { context in
						Text(Self.duration(
							context.date.timeIntervalSince(started), seconds: true))
							.monospacedDigit()
					}
				}
				if vm.safeRun == true {
					LabeledContent("Safe run") {
						HStack(spacing: 4) {
							SafeBadge(compact: true)
							Text("changes are discarded on stop")
								.foregroundStyle(.secondary)
						}
					}
				}
			} else if let lastRan = vm.lastRan {
				LabeledContent("Last ran") {
					if Date().timeIntervalSince(lastRan) < 48 * 3600 {
						Text(lastRan, format: .relative(presentation: .named))
					} else {
						Text(lastRan.formatted(date: .abbreviated, time: .shortened))
					}
				}
			} else {
				LabeledContent("Last ran", value: "Never")
			}
			if let total = vm.totalRuntimeSeconds, total > 0 {
				LabeledContent("Total runtime") {
					if vm.state.isRunning, let started = vm.lastRan {
						TimelineView(.periodic(from: .now, by: 60)) { context in
							Text(Self.duration(
								total + context.date.timeIntervalSince(started),
								seconds: false))
						}
					} else {
						Text(Self.duration(total, seconds: false))
					}
				}
			}
			LabeledContent("Created",
				value: vm.created.formatted(date: .abbreviated, time: .shortened))
		}
	}

	private static func duration(_ seconds: Double, seconds showSeconds: Bool) -> String {
		let allowed: Set<Duration.UnitsFormatStyle.Unit> = showSeconds
			? [.hours, .minutes, .seconds] : [.hours, .minutes]
		return Duration.seconds(seconds).formatted(
			.units(allowed: allowed, width: .narrow, maximumUnitCount: showSeconds ? 3 : 2))
	}

	private func commitMemory() {
		// Bare number = bytes; k/m/g[b] = binary units; decimals accepted. Unparseable
		// reverts; out-of-range lands on min/max via the clamp.
		guard let parsed = ByteSize.parse(memText) else {
			memText = ByteSize.format(vm.memoryBytes)
			return
		}
		let clamped = viewModel.clampMemory(ByteSize.roundToMiB(parsed), floor: memoryFloor)
		memText = ByteSize.format(clamped)
		viewModel.setHardware(vm.name, memoryBytes: clamped)
	}

	private var cpuBinding: Binding<Int> {
		Binding(
			get: { vm.cpuCount },
			set: { viewModel.setHardware(vm.name, cpuCount: $0) })
	}

	private var nestedBinding: Binding<Bool> {
		Binding(
			get: { vm.nestedVirtualization ?? false },
			set: { viewModel.setHardware(vm.name, nested: $0) })
	}

	private var bootBinding: Binding<BootInfo.Mode> {
		Binding(
			get: { vm.boot.mode },
			set: { mode in
				switch mode {
				case .macOS:
					macSwitchSheet = true      // irreversible → sheet, not a silent switch
				case .linuxKernel:
					Task { _ = await viewModel.setKernelBoot(vm.name, enabled: true) }
				case .efi:
					Task { _ = await viewModel.setKernelBoot(vm.name, enabled: false) }
				case .unknown:
					break   // decode fallback only — the picker never offers it
				}
			})
	}

	private func policyBinding(_ key: WritableKeyPath<StartPolicy, Bool>) -> Binding<Bool> {
		Binding(
			get: { (vm.startPolicy ?? StartPolicy())[keyPath: key] },
			set: { value in
				var policy = vm.startPolicy ?? StartPolicy()
				policy[keyPath: key] = value
				viewModel.setStartPolicy(vm.name, policy: policy)
			})
	}
}

// The "cannot be undone" sheet for switching a VM to macOS boot.
struct MacSwitchSheet: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(spacing: 14) {
			Image(systemName: MachmanSymbols.bootMacTab)
				.font(.system(size: 34))
				.foregroundStyle(.secondary)
			Text("Switch to macOS?")
				.font(.title3.weight(.semibold))
			Text("Installing macOS replaces this VM's bootloader configuration. "
				+ "Once installed, the VM cannot switch back to EFI or kernel boot.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				Button("Install from IPSW…") { installFromFile() }
				Button {
					viewModel.startInstall(vm.name, source: .latest)
					dismiss()
				} label: {
					Label("Download Latest", systemImage: MachmanSymbols.installDownload)
				}
				.buttonStyle(.borderedProminent)
				.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		.frame(width: 440)
	}

	private func installFromFile() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		let viewModel = viewModel
		let name = vm.name
		dismiss()
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			DispatchQueue.main.async {
				viewModel.startInstall(name, source: .ipsw(url.path))
			}
		}
	}
}
