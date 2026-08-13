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
				askDiskReferenceOrCopy(viewModel: viewModel, vm: vm, url: url)
			}
		}
	}

	// The copy-or-reference question every disk-file entry point funnels through (picker,
	// tree drop, paste).
	static func askDiskReferenceOrCopy(viewModel: VMListViewModel, vm: String, url: URL) {
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

	// Shared Finder-drop / paste routing: folders become virtiofs mounts, files go through
	// the copy-or-reference question.
	static func handleFileURLs(_ urls: [URL], viewModel: VMListViewModel, vm: String) -> Bool {
		guard !urls.isEmpty else { return false }
		for url in urls {
			var isDir: ObjCBool = false
			FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
			if isDir.boolValue {
				viewModel.addMount(vm, path: url.path, tag: url.lastPathComponent)
			} else {
				askDiskReferenceOrCopy(viewModel: viewModel, vm: vm, url: url)
			}
		}
		return true
	}

	// Paste = the same routing, fed from the general pasteboard's file URLs.
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
