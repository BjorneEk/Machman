//
//  AddFlows.swift
//  MachmanDesktop
//
//  The shared choose-and-add flows behind the toolbar "+" popover and the sidebar tree's
//  context menus: existing-disk (permissive picker + copy-or-reference question — the
//  engine's magic sniff is the real format gate), mount folder, and kernel/initramfs file.
//

import AppKit
import MachmanAPI

@MainActor
enum AddFlows {
	static func chooseExistingDisk(viewModel: VMListViewModel, vm: String) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.diskImage, .data]
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
					viewModel.importDisk(vm, path: url.path)
				case .alertSecondButtonReturn:
					if url.pathExtension.lowercased() == "iso" {
						viewModel.addDisk(vm, .iso(path: url.path))
					} else {
						viewModel.addDisk(vm, .image(path: url.path))
					}
				default:
					break
				}
			}
		}
	}

	// The guest mount tag defaults to the folder's name (editable in the mounts table).
	static func chooseMountFolder(viewModel: VMListViewModel, vm: String) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			DispatchQueue.main.async {
				viewModel.addMount(vm, path: url.path, tag: url.lastPathComponent)
			}
		}
	}

	// Pick a kernel/initramfs file; it is promoted (copied) into the VM's owned set with
	// the file's base name as its tag.
	static func chooseKernelFile(viewModel: VMListViewModel, vm: String, role: KernelRole) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			DispatchQueue.main.async {
				viewModel.promoteKernel(
					vm, role: role, sourcePath: url.path,
					tag: url.deletingPathExtension().lastPathComponent)
			}
		}
	}
}
