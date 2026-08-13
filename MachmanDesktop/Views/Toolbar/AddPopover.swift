//
//  AddPopover.swift
//  MachmanDesktop
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

struct AddButton: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@State private var shown = false

	var body: some View {
		Button {
			shown.toggle()
		} label: {
			Image(systemName: MachmanSymbols.add)
		}
		.help("Add disk, mount, serial port, or device")
		.popover(isPresented: $shown, arrowEdge: .bottom) {
			AddPopover(viewModel: viewModel, vm: vm)
		}
	}
}

struct AddPopover: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@Environment(\.dismiss) private var dismiss
	@State private var addingNewDisk = false

	private let columns = [GridItem(.adaptive(minimum: 64), spacing: 2)]

	var body: some View {
		Group {
			if addingNewDisk {
				NewDiskForm(
					freeGB: viewModel.capabilities.map { ByteSize.toGB($0.freeDiskBytes) },
					back: {
						withAnimation(.snappy(duration: 0.18)) { addingNewDisk = false }
					},
					create: { name, sizeBytes in
						viewModel.addDisk(vm.name, .storage(name: name, sizeBytes: sizeBytes))
						dismiss()
					})
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
				AddTile(symbol: MachmanSymbols.addDiskNew, caption: "New",
					tooltip: "New Disk… (owned image in the VM directory)") {
					withAnimation(.snappy(duration: 0.18)) { addingNewDisk = true }
				}
				AddTile(symbol: MachmanSymbols.addDiskExisting, caption: "Existing",
					tooltip: "Add Existing Disk… (copy in or reference an image)") {
					dismiss()
					chooseExistingDisk()
				}
			}
			Divider()
			section("Mount") {
				AddTile(symbol: MachmanSymbols.addMount, caption: "Folder",
					tooltip: "Add Mount Folder… (shared via virtiofs)") {
					dismiss()
					chooseMountFolder()
				}
			}
			Divider()
			section("Serial") {
				AddTile(symbol: MachmanSymbols.serialConsole, caption: "Console",
					tooltip: "Add Console (virtio)", badge: true) {
					viewModel.addConsolePort(vm.name)
					dismiss()
				}
				uartTile
			}
			if !missing.isEmpty {
				Divider()
				VStack(alignment: .leading, spacing: 4) {
					sectionHeader("Devices")
					LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
						ForEach(missing, id: \.self) { kind in
							AddTile(symbol: kind.displaySymbol,
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
		let gate = viewModel.capabilities?.uartUnavailable
		return AddTile(symbol: MachmanSymbols.serialUart, caption: "UART",
			tooltip: gate?.message ?? "Add UART (PL011)", badge: true) {
			viewModel.addUartPort(vm.name)
			dismiss()
		}
		.disabled(gate != nil)
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
			default: return true
			}
		}
	}

	// MARK: - Flows

	// Same permissive picker + copy-or-reference question as the disks table (the engine's
	// magic sniff is the real format gate).
	private func chooseExistingDisk() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.diskImage, .data]
		let viewModel = viewModel
		let name = vm.name
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			DispatchQueue.main.async {
				let alert = NSAlert()
				alert.messageText = "Add \(url.lastPathComponent)"
				alert.informativeText = "Copy it into the VM (the VM owns an independent "
					+ "copy that travels with it), or reference the original file in place?"
				alert.addButton(withTitle: "Copy into VM")
				alert.addButton(withTitle: "Reference")
				alert.addButton(withTitle: "Cancel")
				switch alert.runModal() {
				case .alertFirstButtonReturn:
					viewModel.importDisk(name, path: url.path)
				case .alertSecondButtonReturn:
					if url.pathExtension.lowercased() == "iso" {
						viewModel.addDisk(name, .iso(path: url.path))
					} else {
						viewModel.addDisk(name, .image(path: url.path))
					}
				default:
					break
				}
			}
		}
	}

	// Folder picker; the guest mount tag defaults to the folder's name (editable later in
	// the mounts table).
	private func chooseMountFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		let viewModel = viewModel
		let name = vm.name
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			DispatchQueue.main.async {
				viewModel.addMount(name, path: url.path, tag: url.lastPathComponent)
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

// Inline "New Disk" form: name + size in GB, capped at the host's free space figure.
private struct NewDiskForm: View {
	let freeGB: Int?
	let back: () -> Void
	let create: (String, UInt64) -> Void
	@State private var name = ""
	@State private var sizeText = ""

	private var sizeGB: Int { Int(sizeText.filter(\.isNumber)) ?? 0 }
	private var valid: Bool {
		!name.isEmpty && sizeGB > 0 && sizeGB <= (freeGB ?? Int.max)
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Button(action: back) {
					Image(systemName: MachmanSymbols.back)
						.font(.system(size: 10, weight: .bold))
				}
				.buttonStyle(.plain)
				.machmanHoverable()
				Text("New Disk")
					.font(.system(size: 12, weight: .semibold))
				Spacer()
			}
			.padding(8)
			Divider()
			VStack(spacing: 8) {
				TextField("Name", text: $name)
					.textFieldStyle(.roundedBorder)
				TextField("Size in GB\(freeGB.map { " (max \($0))" } ?? "")", text: $sizeText)
					.textFieldStyle(.roundedBorder)
				HStack {
					Spacer()
					Button("Create") {
						create(name, ByteSize.fromGB(sizeGB))
					}
					.keyboardShortcut(.defaultAction)
					.disabled(!valid)
				}
			}
			.padding(10)
		}
	}
}
