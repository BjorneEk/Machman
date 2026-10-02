//
//  KernelInspectors.swift
//  MachmanDesktopUI
//
//  Kernel-boot inspectors (1.0.4 UI): the Kernel parent (active-kernel picker + the VM
//  command line) and the per-file kernel/initramfs entries (info, per-kernel command-line
//  override via vm.kernel.setOverride, promote/delete). Command-line editors are
//  multi-line for organizing options; newlines join to spaces on the wire, and edits
//  commit debounced so typing doesn't spam the daemon.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

// MARK: - Kernel parent -----------------------------------------------------------------------

struct KernelParentInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	private var ownedKernels: [OwnedKernelFile] {
		(vm.boot.ownedKernels ?? []).filter { $0.role == .kernel }
	}
	private var activePath: String? {
		let path = vm.boot.kernel?.kernelPath
		return (path?.isEmpty ?? true) ? nil : path
	}

	var body: some View {
		Form {
			Section("Active kernel") {
				Picker("Kernel", selection: activeBinding) {
					Text("None").tag(String?.none)
					ForEach(ownedKernels) { k in
						Text("\(k.tag) — \(k.fileName)").tag(String?.some(k.path))
					}
					// An active path outside the owned set (external reference).
					if let activePath, !ownedKernels.contains(where: { $0.path == activePath }) {
						Text((activePath as NSString).lastPathComponent)
							.tag(String?.some(activePath))
					}
				}
				if vm.boot.mode == .linuxKernel && activePath == nil {
					Label("No kernel selected — the VM cannot start",
						systemImage: MachmanSymbols.warning)
						.font(.caption)
						.foregroundStyle(MachmanColors.warning)
				}
			}
			Section("Command line") {
				CmdlineEditor(
					initial: vm.boot.kernel?.commandLine ?? "",
					commit: { joined in
						var settings = vm.boot.kernel
							?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
						settings.commandLine = joined
						viewModel.updateKernelSettings(vm.name, settings)
					})
				Text("Passed to the kernel at boot unless the active kernel has its own "
					+ "override.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	private var activeBinding: Binding<String?> {
		Binding(
			get: { activePath },
			set: { viewModel.setActiveKernelFile(vm, role: .kernel, path: $0) })
	}
}

// MARK: - Kernel / initramfs entries ----------------------------------------------------------

struct KernelEntryInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let path: String
	// Opens the Tag field on an unsent draft (render scenes).
	var tagDraft: String?

	var body: some View {
		if let entry = KernelEntry(vm: vm, role: .kernel, path: path) {
			Form {
				KernelFileInfoSection(
					viewModel: viewModel, vm: vm, entry: entry, initialTagDraft: tagDraft)
				Section("Command line override") {
					Toggle("Override VM command line", isOn: overrideBinding(entry))
					CmdlineEditor(
						initial: entry.file?.overrideCommandLine ?? "",
						commit: { joined in
							viewModel.setKernelOverride(
								vm.name, path: path, commandLine: joined)
						})
						.disabled(!(entry.file?.overrideEnabled ?? false))
						.opacity((entry.file?.overrideEnabled ?? false)
							? 1 : MachmanColors.disabledOpacity)
					Text("Used instead of the VM command line while this kernel is active.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.disabled(entry.file == nil)   // external references carry no override
				KernelFileActionsSection(viewModel: viewModel, vm: vm, entry: entry)
			}
		} else {
			NoSelectionInspector()
		}
	}

	private func overrideBinding(_ entry: KernelEntry) -> Binding<Bool> {
		Binding(
			get: { entry.file?.overrideEnabled ?? false },
			set: { viewModel.setKernelOverride(vm.name, path: path, overrideEnabled: $0) })
	}
}

// Same shape as the kernel entry inspector, minus the command-line override (spec).
struct InitramfsEntryInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let path: String

	var body: some View {
		if let entry = KernelEntry(vm: vm, role: .initramfs, path: path) {
			Form {
				KernelFileInfoSection(viewModel: viewModel, vm: vm, entry: entry)
				KernelFileActionsSection(viewModel: viewModel, vm: vm, entry: entry)
			}
		} else {
			NoSelectionInspector()
		}
	}
}

// One kernel/initramfs file as the inspectors see it: an owned file, or the active
// settings path pointing outside the owned set (external reference, promotable).
private struct KernelEntry {
	let role: KernelRole
	let path: String
	let file: OwnedKernelFile?   // nil = external reference
	let active: Bool

	init?(vm: VMInfo, role: KernelRole, path: String) {
		self.role = role
		self.path = path
		let owned = (vm.boot.ownedKernels ?? []).first {
			$0.role == role && $0.path == path
		}
		let activePath = role == .kernel
			? vm.boot.kernel?.kernelPath : vm.boot.kernel?.initrdPath
		self.file = owned
		self.active = activePath == path
		if owned == nil && activePath != path { return nil }   // gone entirely
	}

	var label: String { file?.tag ?? (path as NSString).lastPathComponent }
	var fileName: String { file?.fileName ?? (path as NSString).lastPathComponent }
	var owned: Bool { file != nil }
}

private struct KernelFileInfoSection: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let entry: KernelEntry
	var initialTagDraft: String?
	@State private var draftTag = ""
	// The daemon's reason for refusing the last re-tag, until the next edit.
	@State private var tagRefusal: String?

	var body: some View {
		Section(entry.role == .kernel ? "Kernel file" : "Initramfs file") {
			if entry.owned {
				tagField
			} else {
				LabeledContent("Tag", value: entry.label)
			}
			LabeledContent("File", value: entry.fileName)
			LabeledContent("Ownership",
				value: entry.owned ? "Owned (in VM directory)" : "External reference")
			PathRow(label: "Path", path: entry.path) {
				NSWorkspace.shared.activateFileViewerSelecting(
					[URL(fileURLWithPath: entry.path)])
			}
			if entry.active {
				LabeledContent("Status") {
					Label("Active", systemImage: MachmanSymbols.activeEntry)
						.foregroundStyle(MachmanColors.activeEntry)
				}
			}
		}
	}

	// The VM Name field's pattern (PR8): the reason under the field, no alert; a daemon
	// refusal restores the tag and keeps its reason until the next edit.
	private var tagField: some View {
		let refusal = vm.refusal(.renameKernelFile)
		let problem = tagRefusal
			?? viewModel.kernelTagProblem(draftTag, path: entry.path, on: vm)
		return VStack(alignment: .leading, spacing: 3) {
			TextField("Tag", text: $draftTag)
				.onSubmit { commitTag() }
				.disabled(refusal != nil)
				.help(refusal ?? "Re-tags the file (it moves within the VM directory)")
			if let problem {
				FieldProblem(problem)
			}
		}
		.onAppear { draftTag = initialTagDraft ?? entry.label }
		.onChange(of: entry.label) { draftTag = entry.label }
		.onChange(of: draftTag) {
			if draftTag != entry.label { tagRefusal = nil }
		}
	}

	private func commitTag() {
		let current = entry.label
		let sent = viewModel.submitKernelTag(vm, path: entry.path, draft: draftTag) { reason in
			draftTag = current
			tagRefusal = reason
		}
		// Only padded, or unchanged: tidy the field back to the tag.
		if !sent, viewModel.kernelTagProblem(draftTag, path: entry.path, on: vm) == nil {
			draftTag = current
		}
	}
}

private struct KernelFileActionsSection: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let entry: KernelEntry

	// The entity inspectors' one pattern: the icon action leads the last row (the disk
	// and mount trash), the text button trails it.
	var body: some View {
		Section {
			HStack(spacing: 6) {
				if !entry.owned {
					IconButton(
						symbol: MachmanSymbols.promoteDisk,
						tooltip: "Promote to owned — copies the file into the VM directory"
					) {
						viewModel.promoteKernel(
							vm.name, role: entry.role, sourcePath: entry.path,
							tag: URL(fileURLWithPath: entry.path)
								.deletingPathExtension().lastPathComponent)
					}
				} else {
					IconButton(symbol: MachmanSymbols.delete, tooltip: "Delete file…") {
						viewModel.requestDeleteKernel(
							vm.name, path: entry.path, fileName: entry.fileName)
					}
				}
				Spacer()
				if entry.active {
					Button("Deselect") {
						viewModel.setActiveKernelFile(vm, role: entry.role, path: nil)
					}
				} else {
					Button("Select") {
						viewModel.setActiveKernelFile(vm, role: entry.role, path: entry.path)
					}
				}
			}
		}
	}
}

// MARK: - Command-line editor -----------------------------------------------------------------

// Multi-line editor for a single-line value: newlines join to spaces on the wire, so
// options can be organized one per line. Edits commit debounced (and on disappear).
struct CmdlineEditor: View {
	let initial: String
	let commit: (String) -> Void
	@State private var text = ""
	@State private var loaded = false
	@State private var commitTask: Task<Void, Never>?

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			TextEditor(text: $text)
				.font(.system(.callout, design: .monospaced))
				.frame(minHeight: 64, maxHeight: 120)
				.scrollContentBackground(.hidden)
				.padding(4)
				.background(RoundedRectangle(cornerRadius: 5)
					.fill(Color.primary.opacity(0.05)))
			let joined = joinedText
			if joined != text {
				Text("Passed as: \(joined)")
					.font(.system(.caption2, design: .monospaced))
					.foregroundStyle(.tertiary)
					.lineLimit(2)
			}
		}
		.onAppear {
			if !loaded {
				text = initial
				loaded = true
			}
		}
		.onChange(of: text) {
			commitTask?.cancel()
			commitTask = Task {
				try? await Task.sleep(for: .milliseconds(600))
				guard !Task.isCancelled else { return }
				commitIfChanged()
			}
		}
		.onDisappear {
			commitTask?.cancel()
			commitIfChanged()
		}
	}

	private var joinedText: String {
		text.split(whereSeparator: \.isNewline).joined(separator: " ")
	}

	private func commitIfChanged() {
		guard loaded, joinedText != initial else { return }
		commit(joinedText)
	}
}
