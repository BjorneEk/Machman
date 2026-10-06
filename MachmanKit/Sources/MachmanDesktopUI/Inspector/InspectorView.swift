//
//  InspectorView.swift
//  MachmanDesktopUI
//
//  The right-hand inspector (1.0.4 UI): per-selection grouped forms driven by the sidebar
//  tree's selection. This file holds the router + the VM inspector; entity inspectors live
//  in their own files, and unrouted selections fall back to a quiet placeholder.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct InspectorView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var profiles: TerminalProfileStore
	let vm: VMInfo

	var body: some View {
		VStack(spacing: 0) {
			// E22: settings stay locked while an older vmhost runs the VM; a session's own
			// inspector (desktop-local) stays live, and so does what changes no setting inside
			// the others (SettingsLock.swift).
			if let reason = vm.restartToUpdate {
				RestartToUpdateBanner(message: reason)
				Divider()
			}
			Group {
				if viewModel.treeSelection.count > 1 {
					MultiSelectionInspector(viewModel: viewModel, vm: vm)
				} else {
					let node = viewModel.treeSelection.first
					entityInspector(node).id(InspectorIdentity(vm: vm.name, node: node))
				}
			}
			.settingsLocked(vm.restartToUpdate != nil && !showsSession)
		}
		.formStyle(.grouped)
	}

	private var showsSession: Bool {
		guard viewModel.treeSelection.count == 1,
			case .sshSession = viewModel.treeSelection.first else { return false }
		return true
	}

	@ViewBuilder
	private func entityInspector(_ node: SidebarNode?) -> some View {
		switch node {
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

// A different entity is a different inspector: without this identity SwiftUI reuses one switch
// branch's @State across entities, so a kernel's command-line editor kept the previous kernel's
// text (and committed it on disappear) and a staged disk grow applied to the next disk selected.
// The VM is part of the key because entity ids repeat across VMs ("storage:system").
struct InspectorIdentity: Hashable {
	let vm: String
	let node: SidebarNode?
}

struct NoSelectionInspector: View {
	var body: some View {
		VStack(spacing: 8) {
			Image(systemName: MachmanSymbols.inspectorToggle)
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
			Section("\(viewModel.treeSelection.count) items selected") {
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
	// The daemon's reason for refusing the last rename, until the next edit.
	@State private var renameRefusal: String?
	private let initialNameDraft: String?
	@State private var memText = ""
	// What the last Return in the memory field did to the value (clamped, unreadable), until
	// the next edit; committedMemText is the text that answer belongs to.
	@State private var memoryNote: String?
	@State private var committedMemText = ""
	@State private var macSwitchSheet = false

	// `nameDraft` opens the Name field on an unsent draft and `memoryNote` the memory row
	// with a note under it (render scenes).
	init(
		viewModel: VMListViewModel, profiles: TerminalProfileStore, vm: VMInfo,
		nameDraft: String? = nil, memoryNote: String? = nil
	) {
		self.viewModel = viewModel
		self.profiles = profiles
		self.vm = vm
		initialNameDraft = nameDraft
		_memoryNote = State(initialValue: memoryNote)
	}

	private static let noDisplayHelp =
		"No display device — the window can’t open until one is added"

	// An unfinished Mac's bootloader choices are all about its install — macOS… opens it,
	// EFI or Kernel Boot gives it up — so they wait like Install macOS… does (P37). Other
	// modes change at any time; the daemon applies them at the next start.
	private var bootPickerRefusal: String? {
		vm.boot.mode == .macOS ? vm.refusal(.installMacOS) : nil
	}

	// macOS guests carry install-time hardware minimums; other modes have none.
	private var cpuFloor: Int { max(1, vm.boot.minCPUCount ?? 1) }
	private var cpuRange: ClosedRange<Int> {
		let upper = max(viewModel.capabilities?.maxCPUCount ?? cpuFloor, cpuFloor)
		return cpuFloor...upper
	}

	var body: some View {
		Form {
			Section("Machine") {
				nameField
				LabeledContent {
					Stepper(
						vm.cpuCount == 1 ? "1 core" : "\(vm.cpuCount) cores",
						value: cpuBinding, in: cpuRange)
				} label: {
					Label("CPUs", systemImage: MachmanSymbols.cpu)
				}
				memoryRow
				// Its own row: the field keeps its place while the note comes and goes.
				if let memoryNote {
					FieldProblem(memoryNote)
				}
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
				} else if vm.boot.mode == .unknown {
					// A mode a newer Machman wrote (C11): nothing here can pick or keep it.
					LabeledContent("Bootloader") {
						HStack(spacing: 4) {
							Image(systemName: MachmanSymbols.help)
								.accessibilityHidden(true)
							Text(BootInfo.Mode.unknown.displayLabel)
						}
					}
					.help(BootInfo.newerModeReason)
				} else {
					Picker("Bootloader", selection: bootBinding) {
						Text("EFI").tag(BootInfo.Mode.efi)
						Text("Kernel Boot").tag(BootInfo.Mode.linuxKernel)
						// Installing is stop-first (H41): the row waits while the VM runs, as
						// the sheet's buttons and Install macOS… do.
						Text("macOS…").tag(BootInfo.Mode.macOS)
							.disabled(vm.refusal(.installMacOS) != nil)
					}
					.disabled(viewModel.isInstalling(vm) || bootPickerRefusal != nil)
					.help(bootPickerRefusal ?? "")
					// Already in macOS mode but not installed (a failed or cancelled install,
					// or an unfinished Mac's copy): re-selecting macOS can't fire the picker,
					// so the install needs its own way in.
					if vm.boot.mode == .macOS && !viewModel.isInstalling(vm) {
						Button("Install macOS…") { macSwitchSheet = true }
							.stopFirst(vm, .installMacOS)
					}
				}
				// EFI and kernel boots only: a newer Machman's mode may not take it either.
				if vm.boot.mode != .macOS && vm.boot.mode != .unknown {
					Toggle("Allow nested virtualization", isOn: nestedBinding)
						.disabled(
							viewModel.capabilities?.nestedVirtualizationSupported == false)
						.help(viewModel.capabilities?.nestedVirtualizationSupported == false
							? "This host cannot expose virtualization extensions to guests"
							: "Exposes virtualization extensions to the guest (EFI/Linux)")
				}
			}

			Section("Default start") {
				HStack(spacing: 6) {
					Toggle("Open window", isOn: policyBinding(\.windowed))
					if !vm.hasEnabledGraphics {
						Image(systemName: MachmanSymbols.warning)
							.font(.system(size: 11))
							.foregroundStyle(MachmanColors.warning)
							.help(Self.noDisplayHelp)
							.accessibilityLabel(Self.noDisplayHelp)
					}
				}
				// Each dims while the other is on, with the daemon's own reason (H52).
				Toggle("Safe mode", isOn: policyBinding(\.safe))
					.disabled(policy.safeRefusal != nil)
					.help(policy.safeRefusal ?? "")
				// A per-VM launchd job starts the VM at login (LaunchAgentManager), with no
				// daemon involved.
				Toggle("Start at login", isOn: policyBinding(\.autostart))
					.disabled(policy.autostartRefusal != nil)
					.help(policy.autostartRefusal ?? "")
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
					VMStatusDot(vm: vm, size: 7)
					Text(vm.stateLabel)
				}
			}
			if vm.state.isRunning, let started = vm.lastRan {
				LabeledContent("Uptime") {
					// The timeline only ticks; the time counted is MachmanClock's (Q16).
					TimelineView(.periodic(from: .now, by: 1)) { _ in
						Text(Self.duration(
							MachmanClock.now().timeIntervalSince(started), seconds: true))
							.monospacedDigit()
					}
				}
				if vm.safeRun == true {
					LabeledContent("Safe run") {
						HStack(spacing: 4) {
							SafeBadge(compact: true)
							Text("Changes are discarded on stop")
								.foregroundStyle(.secondary)
						}
					}
				}
			} else if let lastRan = vm.lastRan {
				LabeledContent("Last ran") {
					let now = MachmanClock.now()
					if now.timeIntervalSince(lastRan) < 48 * 3600 {
						Text(Self.relative(lastRan, to: now))
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
						TimelineView(.periodic(from: .now, by: 60)) { _ in
							Text(Self.duration(
								total + MachmanClock.now().timeIntervalSince(started),
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

	// “1 hour ago”, counted from `now` (Text's .relative format reads the system clock).
	private static func relative(_ date: Date, to now: Date) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.dateTimeStyle = .named
		return formatter.localizedString(for: date, relativeTo: now)
	}

	private static func duration(_ seconds: Double, seconds showSeconds: Bool) -> String {
		let allowed: Set<Duration.UnitsFormatStyle.Unit> = showSeconds
			? [.hours, .minutes, .seconds] : [.hours, .minutes]
		return Duration.seconds(seconds).formatted(
			.units(allowed: allowed, width: .narrow, maximumUnitCount: showSeconds ? 3 : 2))
	}

	// A name the rule or the list refuses is explained under the field while it is typed,
	// and Return sends nothing (PR8). One the daemon refuses doesn't stay in the field, but
	// its reason stays under it until the next edit.
	private var nameField: some View {
		VStack(alignment: .leading, spacing: 3) {
			TextField("Name", text: $draftName)
				.onSubmit {
					viewModel.submitRename(
						vm, draft: draftName, profiles: profiles,
						reverted: { draftName = vm.name }, refused: { renameRefusal = $0 })
				}
				.stopFirst(vm, .renameVM)
			if let problem = renameRefusal ?? viewModel.vmRenameProblem(draftName, for: vm) {
				FieldProblem(problem)
			}
		}
		.servedDraft($draftName, of: vm.name, seed: initialNameDraft, refusal: $renameRefusal)
	}

	private var memoryRow: some View {
		LabeledContent {
			TextField("", text: $memText, prompt: Text("8 GB"))
				.inspectorNumberField(width: 90)
				.onChange(of: memText) {
					// Permissive while typing; interpretation happens on submit.
					let filtered = String(memText
						.filter { "0123456789.,kmgbKMGB ".contains($0) }.prefix(12))
					if filtered != memText { memText = filtered }
					if memText != committedMemText { memoryNote = nil }
				}
				.onSubmit { commitMemory() }
				.help("\(vm.memoryBytes.formatted()) bytes, and a bare number means GB")
		} label: {
			Label("Memory", systemImage: MachmanSymbols.memory)
		}
		.onAppear { showMemory() }
		.onChange(of: vm.memoryBytes) { showMemory() }
	}

	private func showMemory() {
		committedMemText = ByteSize.format(vm.memoryBytes)
		memText = committedMemText
	}

	// Bare number = GB, k/m/g[b] = binary units, decimals accepted (decision 14). An
	// unreadable entry reverts, an out-of-range one lands on the min/max; both say so.
	private func commitMemory() {
		let entry = viewModel.submitMemory(vm, text: memText)
		committedMemText = ByteSize.format(entry.bytes ?? vm.memoryBytes)
		memText = committedMemText
		memoryNote = entry.note
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

	private var policy: StartPolicy { vm.startPolicy ?? StartPolicy() }

	private func policyBinding(_ key: WritableKeyPath<StartPolicy, Bool>) -> Binding<Bool> {
		Binding(
			get: { policy[keyPath: key] },
			set: { value in
				var updated = policy
				updated[keyPath: key] = value
				viewModel.setStartPolicy(vm.name, policy: updated)
			})
	}
}

// The sheet that installs macOS: a switch from EFI or kernel boot that can't be undone, or
// a retry on a VM already in macOS mode (a failed or cancelled install, an unfinished Mac's
// copy). Irreversible and a multi-GB download, so Return presses nothing (H45, C21).
struct MacSwitchSheet: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@Environment(\.dismiss) private var dismiss

	private var retry: Bool { vm.boot.mode == .macOS }

	var body: some View {
		VStack(spacing: 14) {
			Image(systemName: MachmanSymbols.bootMacTab)
				.font(.system(size: 34))
				.foregroundStyle(.secondary)
			Text(retry ? "Install macOS?" : "Switch to macOS?")
				.font(.title3.weight(.semibold))
			Text(retry
				? "Download the latest macOS, or install it from an IPSW file you have."
				: "Once macOS is installed, this VM can’t switch back to EFI or kernel boot.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				// Stop-first, like the picker row that opens this sheet (H41).
				Button("Install from IPSW…") { installFromFile() }
					.stopFirst(vm, .installMacOS)
				Button {
					viewModel.startInstall(vm.name, source: .latest)
					dismiss()
				} label: {
					Label("Download Latest", systemImage: MachmanSymbols.installDownload)
				}
				.stopFirst(vm, .installMacOS)
			}
		}
		.padding(22)
		.frame(width: 440)
	}

	// The New Mac flow's picker (AddFlows.chooseRestoreImage); Cancel installs nothing.
	private func installFromFile() {
		let viewModel = viewModel
		let name = vm.name
		dismiss()
		AddFlows.chooseRestoreImage { path in
			viewModel.startInstall(name, source: .ipsw(path))
		}
	}
}
