//
//  AddFlows+Panels.swift
//  MachmanDesktop
//
//  The choose-and-add pickers (NSOpenPanel) and the pasteboard's file URLs, feeding the
//  shared routing in AddFlows (ViewModels/AddFlows.swift): existing-disk (permissive picker +
//  copy-or-reference question), mount folder, and kernel/initramfs file.
//

import AppKit
import MachmanAPI

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
	static func pasteboardFileURLs() -> [URL] {
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
}
