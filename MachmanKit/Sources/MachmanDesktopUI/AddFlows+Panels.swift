//
//  AddFlows+Panels.swift
//  MachmanDesktopUI
//
//  The choose-and-add pickers (NSOpenPanel) and the pasteboard's file URLs, feeding the
//  shared routing in AddFlows (MachmanDesktopCore): existing-disk (permissive picker +
//  copy-or-reference question), mount folder, kernel/initramfs file, and the macOS restore
//  image a new Mac VM installs from.
//

import AppKit
import MachmanAPI
import MachmanDesktopCore

@MainActor
extension AddFlows {
	static func chooseExistingDisk(viewModel: VMListViewModel, vm: String) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.diskImage, .data]
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			DispatchQueue.main.async {
				askDiskReferenceOrCopy(viewModel: viewModel, vm: vm, url: url)
			}
		}
	}

	// Paste = the shared routing, fed from the general pasteboard's file URLs.
	public static func pasteboardFileURLs() -> [URL] {
		NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [
			.urlReadingFileURLsOnly: true,
		]) as? [URL] ?? []
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

	// Pick a macOS restore image (IPSW) — unfiltered, like the Install macOS sheet's. Cancel
	// calls nothing, so nothing is created.
	static func chooseRestoreImage(_ chosen: @escaping @MainActor (String) -> Void) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			DispatchQueue.main.async {
				chosen(url.path)
			}
		}
	}
}
