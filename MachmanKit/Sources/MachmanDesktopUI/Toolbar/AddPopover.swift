//
//  AddPopover.swift
//  MachmanDesktopUI
//
//  The toolbar "+" popover (1.0.4 UI): icon tiles for Disk / Mount / Serial / Devices.
//  Boot- and capability-aware — the Devices grid offers only kinds valid for this VM's boot
//  that aren't attached yet, and the UART tile dims while the host gates the private UART
//  backend. Disk "New" swaps to an inline name/size form (the template-chooser pattern);
//  "Existing" runs the same choose → copy-or-reference flow as the disks table.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct AddButton: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@State private var shown = false

	private static let title = "Add Disk, Mount, Serial Port, or Device"

	var body: some View {
		Button {
			shown.toggle()
		} label: {
			// Titled for the toolbar's » menu and VoiceOver; the bar shows the icon (H33).
			Label(Self.title, systemImage: MachmanSymbols.add)
				.labelStyle(.iconOnly)
		}
		.help(Self.title)
		.popover(isPresented: $shown, arrowEdge: .bottom) {
			AddPopover(viewModel: viewModel, vm: vm)
		}
	}
}

struct AddPopover: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@Environment(\.dismiss) private var dismiss
	@State private var addingNewDisk: Bool
	private let diskName: String
	private let diskSize: String

	private let columns = [GridItem(.adaptive(minimum: 64), spacing: 2)]

	// `newDisk` opens straight on the New Disk form, `diskName`/`diskSize` pre-fill it
	// (render scenes).
	init(
		viewModel: VMListViewModel, vm: VMInfo, newDisk: Bool = false,
		diskName: String = "", diskSize: String = ""
	) {
		self.viewModel = viewModel
		self.vm = vm
		_addingNewDisk = State(initialValue: newDisk)
		self.diskName = diskName
		self.diskSize = diskSize
	}

	var body: some View {
		Group {
			if addingNewDisk {
				NewDiskForm(
					viewModel: viewModel, vm: vm, name: diskName, sizeText: diskSize,
					back: {
						withAnimation(.snappy(duration: 0.18)) { addingNewDisk = false }
					},
					created: { dismiss() })
			} else {
				tiles
			}
		}
		.frame(width: 296)
	}

	private var tiles: some View {
		let missing = missingKinds
		return VStack(alignment: .leading, spacing: 8) {
			section("Disk") {
				AddTile("New Disk…", symbol: MachmanSymbols.addDiskNew, caption: "New",
					tooltip: "New Disk… (owned image in the VM directory)") {
					withAnimation(.snappy(duration: 0.18)) { addingNewDisk = true }
				}
				AddTile("Add Existing Disk…", symbol: MachmanSymbols.addDiskExisting,
					caption: "Existing",
					tooltip: "Add Existing Disk… (copy in or reference an image)") {
					dismiss()
					AddFlows.chooseExistingDisk(viewModel: viewModel, vm: vm.name)
				}
			}
			Divider()
			section("Mount") {
				AddTile("Add Mount Folder…", symbol: MachmanSymbols.addMount, caption: "Folder",
					tooltip: "Add Mount Folder… (shared via virtiofs)") {
					dismiss()
					AddFlows.chooseMountFolder(viewModel: viewModel, vm: vm.name)
				}
			}
			Divider()
			section("Serial") {
				// The daemon refuses port changes while the VM runs (P14).
				AddTile("Add Console", symbol: MachmanSymbols.serialConsole, caption: "Console",
					tooltip: "Add Console (virtio)",
					disabledReason: vm.refusal(.changeSerialPorts), badge: true) {
					viewModel.addConsolePort(vm.name)
					dismiss()
				}
				uartTile
			}
			if hasInstallerTiles {
				Divider()
				section("Installers") {
					// The guest-setup payload served over the share — its own section.
					AddTile("Add Guest Setup", symbol: MachmanSymbols.deviceGuestSetup,
						caption: "Guest Setup",
						tooltip: "Add Guest Setup — one script that sets up console "
							+ "logins, SSH, and boot automounts from inside the guest") {
						viewModel.addDevice(vm.name, kind: .guestSetup)
						dismiss()
					}
				}
			}
			if !missing.isEmpty {
				Divider()
				VStack(alignment: .leading, spacing: 4) {
					sectionHeader("Devices")
					LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
						ForEach(missing, id: \.self) { kind in
							AddTile("Add \(kind.displayLabel)", symbol: kind.displaySymbol,
								caption: kind.displayLabel,
								tooltip: "Add \(kind.displayLabel)") {
								viewModel.addDevice(vm.name, kind: kind)
								dismiss()
							}
						}
					}
				}
			}
		}
		.padding(10)
	}

	private var uartTile: some View {
		// The host gate explains first: stopping the VM wouldn't help there.
		let gate = viewModel.capabilities?.uartUnavailable
		let refusal = vm.refusal(.changeSerialPorts)
		return AddTile("Add UART", symbol: MachmanSymbols.serialUart, caption: "UART",
			tooltip: "Add UART (PL011)", disabledReason: gate?.message ?? refusal,
			badge: true) {
			viewModel.addUartPort(vm.name)
			dismiss()
		}
	}

	private func attached(_ kind: DeviceKind) -> Bool {
		(vm.devices ?? []).contains { $0.kind == kind }
	}

	// The one installer fits any boot; present but disabled counts as attached.
	private var hasInstallerTiles: Bool {
		!attached(.guestSetup)
	}

	// Kinds the daemon would accept for this boot that aren't attached yet (present but
	// disabled still counts as attached — re-enable it instead).
	private var missingKinds: [DeviceKind] {
		let attached = Set((vm.devices ?? []).map(\.kind))
		let macGuest = vm.boot.mode == .macOS
		return DeviceKind.allKinds.filter { kind in
			guard !attached.contains(kind) else { return false }
			switch kind {
			case .trackpad: return macGuest
			case .clipboard, .rosetta: return !macGuest
			case _ where kind.isInstaller:
				return false   // installer tiles live in their own section above
			default: return true
			}
		}
	}

	// MARK: - Pieces

	private func section<Content: View>(
		_ title: String, @ViewBuilder tiles: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			sectionHeader(title)
			HStack(spacing: 2) { tiles() }
		}
	}

	private func sectionHeader(_ title: String) -> some View {
		Text(title)
			.font(.system(size: 10, weight: .semibold))
			.foregroundStyle(.secondary)
	}
}

// Inline "New Disk" form: name + size in GB (decimals fine), capped at the host's free
// space figure. A disabled Create always says why — once anything is typed; the untouched
// form's placeholders say what to enter.
private struct NewDiskForm: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let back: () -> Void
	let created: () -> Void
	@State private var name: String
	@State private var sizeText: String

	init(
		viewModel: VMListViewModel, vm: VMInfo, name: String, sizeText: String,
		back: @escaping () -> Void, created: @escaping () -> Void
	) {
		self.viewModel = viewModel
		self.vm = vm
		self.back = back
		self.created = created
		_name = State(initialValue: name)
		_sizeText = State(initialValue: sizeText)
	}

	private var freeText: String? {
		viewModel.capabilities.map { ByteSize.display($0.freeDiskBytes) }
	}
	private var problem: String? {
		viewModel.newDiskProblem(on: vm, name: name, sizeText: sizeText)
	}

	var body: some View {
		VStack(spacing: 0) {
			PopoverPageHeader(title: "New Disk", back: back)
			Divider()
			VStack(spacing: 8) {
				TextField("Name", text: $name)
					.textFieldStyle(.roundedBorder)
				TextField("Size in GB\(freeText.map { " (up to \($0))" } ?? "")", text: $sizeText)
					.textFieldStyle(.roundedBorder)
				if let problem, !(name.isEmpty && sizeText.isEmpty) {
					FieldProblem(problem)
				}
				HStack {
					Spacer()
					Button("Create") {
						if viewModel.createDisk(on: vm, name: name, sizeText: sizeText) {
							created()
						}
					}
					.keyboardShortcut(.defaultAction)
					.disabled(problem != nil)
				}
			}
			.padding(10)
		}
		// "Up to" and the cap judge today's free space, not the connection's (P44).
		.task { await viewModel.refreshFreeSpace() }
	}
}
