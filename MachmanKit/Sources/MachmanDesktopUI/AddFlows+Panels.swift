//
//  AddFlows+Panels.swift
//  MachmanDesktopUI
//
//  The choose-and-add pickers and the pasteboard's file URLs, feeding the shared routing in
//  AddFlows (MachmanDesktopCore): existing-disk (permissive picker + copy-or-reference
//  question), mount folder, kernel/initramfs file, and the macOS restore image a new Mac VM
//  installs from. Every picker asks through OpenPanels (Q21): NSOpenPanel in the app, an
//  answer of its own in a test; each says what it is for and names its button (H63).
//

import AppKit
import MachmanAPI
import MachmanDesktopCore

// Who answers an add flow's open panel: the system's NSOpenPanel, or a test's answer. The
// answer is the picked URL, nil for Cancel, delivered on the main actor.
struct OpenPanels {
	let choose: @MainActor (OpenPanelRequest, @escaping @MainActor (URL?) -> Void) -> Void

	static let system = OpenPanels { request, answer in
		let panel = NSOpenPanel()
		panel.canChooseFiles = request.pick == .file
		panel.canChooseDirectories = request.pick == .folder
		panel.allowsMultipleSelection = false
		panel.message = request.message
		panel.prompt = request.prompt
		if !request.contentTypes.isEmpty {
			panel.allowedContentTypes = request.contentTypes
		}
		panel.begin { response in
			let url = response == .OK ? panel.url : nil
			DispatchQueue.main.async { answer(url) }
		}
	}
}

@MainActor
extension AddFlows {
	static func chooseExistingDisk(
		viewModel: VMListViewModel, vm: String, panels: OpenPanels = .system
	) {
		panels.choose(.existingDisk(vm: vm)) { url in
			guard let url else { return }
			askDiskReferenceOrCopy(viewModel: viewModel, vm: vm, url: url)
		}
	}

	// Paste = the shared routing, fed from the general pasteboard's file URLs.
	public static func pasteboardFileURLs() -> [URL] {
		NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [
			.urlReadingFileURLsOnly: true,
		]) as? [URL] ?? []
	}

	// The guest mount tag defaults to the folder's name (renamable in the mount's inspector).
	static func chooseMountFolder(
		viewModel: VMListViewModel, vm: String, panels: OpenPanels = .system
	) {
		panels.choose(.mountFolder(vm: vm)) { url in
			guard let url else { return }
			viewModel.addMount(vm, path: url.path, tag: url.lastPathComponent)
		}
	}

	// Pick a kernel/initramfs file; it is promoted (copied) into the VM's owned set under
	// the tag its file name suggests.
	static func chooseKernelFile(
		viewModel: VMListViewModel, vm: String, role: KernelRole, panels: OpenPanels = .system
	) {
		panels.choose(.kernelFile(role, vm: vm)) { url in
			guard let url else { return }
			viewModel.promoteKernel(
				vm, role: role, sourcePath: url.path,
				tag: KernelTag.suggested(forFile: url.path))
		}
	}

	// Pick a macOS restore image (.ipsw only): the New Mac flow's and the Install macOS
	// sheet's one picker. Cancel calls nothing, so nothing is created or installed.
	static func chooseRestoreImage(
		panels: OpenPanels = .system, _ chosen: @escaping @MainActor (String) -> Void
	) {
		panels.choose(.restoreImage) { url in
			guard let url else { return }
			chosen(url.path)
		}
	}

	// New VM ▸ macOS ▸ From an IPSW File…: the VM is created only once a file is picked
	// (H21), and then installs from it.
	static func newMacFromFile(viewModel: VMListViewModel, panels: OpenPanels = .system) {
		chooseRestoreImage(panels: panels) { path in
			Task { await viewModel.createMacVM(source: .ipsw(path)) }
		}
	}
}
