//
//  AddFlows.swift
//  MachmanDesktop
//
//  The shared add routing behind the toolbar "+" popover, the sidebar tree's context menus,
//  Finder drops and paste: every disk file funnels through the copy-or-reference question
//  (the engine's magic sniff is the real format gate), folders become mounts. The pickers
//  that feed it (NSOpenPanel) extend this type beside the views (Views/AddFlows+Panels.swift).
//

import Foundation
import MachmanAPI

@MainActor
enum AddFlows {
	// The copy-or-reference question every disk-file entry point funnels through (picker,
	// tree drop, paste): queued on the view model, presented as a confirmationDialog.
	static func askDiskReferenceOrCopy(viewModel: VMListViewModel, vm: String, url: URL) {
		viewModel.pendingDiskAdd = VMListViewModel.PendingDiskAdd(vm: vm, url: url)
	}

	// The dialog's Copy / Reference resolutions.
	static func addDiskCopy(viewModel: VMListViewModel, vm: String, url: URL) {
		viewModel.importDisk(vm, path: url.path)
	}

	static func addDiskReference(viewModel: VMListViewModel, vm: String, url: URL) {
		if url.pathExtension.lowercased() == "iso" {
			viewModel.addDisk(vm, .iso(path: url.path))
		} else {
			viewModel.addDisk(vm, .image(path: url.path))
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
}
