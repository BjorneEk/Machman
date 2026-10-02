//
//  VMPickerPopover.swift
//  MachmanDesktopUI
//
//  The VM indicator's dropdown: searchable VM list with per-row quick-action menus, plus
//  the New VM template chooser (blank / default → vm.create {template}; macOS → its install
//  source, then create and install). In the quick actions, state alternates (Start ↔ Shut
//  Down) stay hidden; stop-first actions show dimmed with the reason while the VM runs (P14),
//  as in the tree and the inspector.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct VMPickerPopover: View {
	@ObservedObject var viewModel: VMListViewModel
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var page: Page

	private enum Page { case list, templates, macSource }

	// `templates` opens straight on the New VM template chooser, `macSource` on the macOS
	// template's install-source page (render scenes).
	init(viewModel: VMListViewModel, templates: Bool = false, macSource: Bool = false) {
		self.viewModel = viewModel
		_page = State(initialValue: macSource ? .macSource : templates ? .templates : .list)
	}

	private var filtered: [VMInfo] {
		query.isEmpty
			? viewModel.vms
			: viewModel.vms.filter { $0.name.localizedCaseInsensitiveContains(query) }
	}

	var body: some View {
		Group {
			switch page {
			case .list:
				pickerList
			case .templates:
				NewVMTemplateView {
					show(.list)
				} create: { template in
					dismiss()
					Task {
						if let name = await viewModel.createVM(template: template) {
							viewModel.select(name: name)
						}
					}
				} installMac: {
					show(.macSource)
				}
			case .macSource:
				// H21: the VM is created only once a source is picked (VMListViewModel+NewMac).
				NewMacSourceView {
					show(.templates)
				} latest: {
					dismiss()
					Task { await viewModel.createMacVM(source: .latest) }
				} fromFile: {
					let viewModel = viewModel
					dismiss()
					AddFlows.chooseRestoreImage { path in
						Task { await viewModel.createMacVM(source: .ipsw(path)) }
					}
				}
			}
		}
		.frame(width: 300)
	}

	private func show(_ next: Page) {
		withAnimation(.snappy(duration: 0.18)) { page = next }
	}

	private var pickerList: some View {
		VStack(spacing: 0) {
			HStack(spacing: 5) {
				Image(systemName: MachmanSymbols.search)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
				TextField("Find a VM", text: $query)
					.textFieldStyle(.plain)
			}
			.padding(8)
			Divider()
			ScrollView {
				VStack(spacing: 1) {
					ForEach(filtered) { vm in
						VMPickerRow(viewModel: viewModel, vm: vm) { dismiss() }
					}
					if filtered.isEmpty {
						Text("No VMs match “\(query)”")
							.font(.callout)
							.foregroundStyle(.secondary)
							.padding(12)
					}
				}
				.padding(4)
			}
			.frame(maxHeight: 300)
			Divider()
			Button {
				show(.templates)
			} label: {
				Label("New VM…", systemImage: MachmanSymbols.add)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 10)
					.padding(.vertical, 7)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.machmanHoverable(radius: 0)
		}
	}
}

private struct VMPickerRow: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let dismiss: () -> Void
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 8) {
			Button {
				viewModel.select(name: vm.name)
				dismiss()
			} label: {
				HStack(spacing: 8) {
					VMStatusDot(vm: vm, size: 7)
					VStack(alignment: .leading, spacing: 1) {
						HStack(spacing: 4) {
							Text(vm.name)
								.font(.system(size: 12, weight: .medium))
							if vm.safeRun == true { SafeBadge(compact: true) }
						}
						if vm.isUnresponsive {
							NotRespondingBadge(size: 9)
						} else {
							BootBadge(mode: vm.boot.mode, size: 9)
						}
					}
					Spacer()
					if vm.name == viewModel.selectedName {
						Image(systemName: MachmanSymbols.selectedItem)
							.font(.system(size: 10, weight: .semibold))
							.foregroundStyle(MachmanColors.selection)
					}
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			Menu {
				quickActions
			} label: {
				Image(systemName: MachmanSymbols.more)
					.font(.system(size: 11))
			}
			.menuStyle(.borderlessButton)
			.menuIndicator(.hidden)
			.frame(width: 22)
			.opacity(hovering ? 1 : 0.35)
			.help("Actions for \(vm.name)")
			.accessibilityLabel("Actions for \(vm.name)")
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 5)
		.background(RoundedRectangle(cornerRadius: 6)
			.fill(Color.primary.opacity(hovering ? MachmanColors.hoverOverlay : 0)))
		.onHover { hovering = $0 }
	}

	// Start follows the VM's start policy; Start Safe overrides only safety (decision 7).
	@ViewBuilder
	private var quickActions: some View {
		if viewModel.canStart(vm) {
			Button("Start") { viewModel.startPolicyDriven(vm) }
			Button("Start Safe") { viewModel.startPolicyDriven(vm, .safe) }
		}
		if vm.state.isRunning {
			Button("Shut Down") { viewModel.stopVM(vm.name, mode: .soft) }
			Button("Force Stop") { viewModel.stopVM(vm.name, mode: .force) }
		}
		Divider()
		Button("Open") {
			viewModel.select(name: vm.name)
			dismiss()
		}
		if let action = vm.windowAction {
			Button(action == .close ? "Close Window" : "Open Window") {
				if action == .close {
					viewModel.closeWindow(vm.name)
				} else {
					viewModel.openWindow(vm.name)
				}
			}
		}
		Divider()
		Button("Delete…", role: .destructive) {
			dismiss()
			viewModel.deleteVM(vm)
		}
		.stopFirst(vm, .deleteVM)
	}
}

// Template chooser shown inside the picker popover after "New VM…". Captions state what
// the daemon's template actually seeds (LocalMachman.createVM); the macOS template leads on
// to its install source (H21).
private struct NewVMTemplateView: View {
	let back: () -> Void
	let create: (VMTemplate?) -> Void
	let installMac: () -> Void

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Button(action: back) {
					Image(systemName: MachmanSymbols.back)
						.font(.system(size: 10, weight: .bold))
				}
				.buttonStyle(.plain)
				.machmanHoverable()
				.help("Back to the VM list")
				.accessibilityLabel("Back")
				Text("New VM")
					.font(.system(size: 12, weight: .semibold))
				Spacer()
			}
			.padding(8)
			Divider()
			VStack(spacing: 2) {
				Self.row(title: "Blank", caption: "No devices — add exactly what you need",
					action: { create(.blank) }) {
					Image(systemName: MachmanSymbols.templateBlank).font(.system(size: 15))
				}
				Self.row(title: "Default", caption: "Keyboard, pointer, display, audio, network, "
					+ "clipboard — add disks yourself", action: { create(.default) }) {
					TuxIcon(size: 16)
				}
				Self.row(title: "macOS", caption: "Installs macOS, downloaded or from an IPSW file",
					action: installMac) {
					Image(systemName: MachmanSymbols.bootMacTab).font(.system(size: 15))
				}
			}
			.padding(6)
		}
	}

	// One choice row; NewMacSourceView's rows are built the same way.
	static func row(
		title: String, caption: String, action: @escaping () -> Void,
		@ViewBuilder icon: @escaping () -> some View
	) -> some View {
		Button {
			action()
		} label: {
			HStack(spacing: 9) {
				icon().frame(width: 22)
				VStack(alignment: .leading, spacing: 1) {
					Text(title).font(.system(size: 12, weight: .medium))
					Text(caption)
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
						.multilineTextAlignment(.leading)
				}
				Spacer()
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.machmanHoverable(radius: 6)
	}
}

// The macOS template's second step (H21, decision 15): where the install comes from. The VM
// is created only once a source is picked, so backing out or cancelling the Open panel
// leaves nothing behind.
private struct NewMacSourceView: View {
	let back: () -> Void
	let latest: () -> Void
	let fromFile: () -> Void

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Button(action: back) {
					Image(systemName: MachmanSymbols.back)
						.font(.system(size: 10, weight: .bold))
				}
				.buttonStyle(.plain)
				.machmanHoverable()
				.help("Back")
				Text("macOS")
					.font(.system(size: 12, weight: .semibold))
				Spacer()
			}
			.padding(8)
			Divider()
			VStack(spacing: 2) {
				NewVMTemplateView.row(
					title: "Download Latest", caption: "The newest macOS this Mac can run",
					action: latest) {
					Image(systemName: MachmanSymbols.installDownload).font(.system(size: 15))
				}
				NewVMTemplateView.row(
					title: "From an IPSW File…",
					caption: "A macOS restore image you already have", action: fromFile) {
					Image(systemName: MachmanSymbols.installFromFile).font(.system(size: 15))
				}
			}
			.padding(6)
		}
	}
}
