//
//  AddFlows.swift
//  MachmanDesktopCore
//
//  The shared add routing behind the toolbar "+" popover, the sidebar tree's context menus,
//  Finder drops and paste: every disk file funnels through the copy-or-reference question
//  (the engine's magic sniff is the real format gate), folders become mounts. The pickers
//  that feed it (NSOpenPanel) extend this type in MachmanDesktopUI (AddFlows+Panels.swift).
//

import Foundation
import MachmanAPI

@MainActor
public enum AddFlows {
	// The copy-or-reference question every disk-file entry point funnels through (picker,
	// tree drop, paste): ONE question for all the files of one gesture, queued on the view
	// model behind any question already showing, presented as a confirmationDialog.
	public static func askDiskReferenceOrCopy(
		viewModel: VMListViewModel, vm: String, urls: [URL]
	) {
		viewModel.askDiskAdd(vm: vm, urls: urls)
	}

	public static func askDiskReferenceOrCopy(viewModel: VMListViewModel, vm: String, url: URL) {
		askDiskReferenceOrCopy(viewModel: viewModel, vm: vm, urls: [url])
	}

	// The dialog's Copy / Reference resolutions, applied to every file it asked about.
	public static func addDiskCopies(
		viewModel: VMListViewModel, _ pending: VMListViewModel.PendingDiskAdd
	) {
		viewModel.importDisks(pending.vm, paths: pending.urls.map(\.path))
	}

	public static func addDiskReferences(
		viewModel: VMListViewModel, _ pending: VMListViewModel.PendingDiskAdd
	) {
		viewModel.addDisks(pending.vm, pending.urls.map(newDisk(for:)))
	}

	static func newDisk(for url: URL) -> NewDisk {
		url.pathExtension.lowercased() == "iso" ? .iso(path: url.path) : .image(path: url.path)
	}

	// Shared Finder-drop / paste routing: folders become virtiofs mounts, files go through
	// one copy-or-reference question.
	public static func handleFileURLs(
		_ urls: [URL], viewModel: VMListViewModel, vm: String
	) -> Bool {
		guard !urls.isEmpty else { return false }
		var files: [URL] = []
		for url in urls {
			var isDir: ObjCBool = false
			FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
			if isDir.boolValue {
				viewModel.addMount(vm, path: url.path, tag: url.lastPathComponent)
			} else {
				files.append(url)
			}
		}
		if !files.isEmpty {
			askDiskReferenceOrCopy(viewModel: viewModel, vm: vm, urls: files)
		}
		return true
	}

	// Paste into a VM: copied tree entities by their own kinds when the clipboard holds any,
	// otherwise the pasteboard's file URLs by the Finder routing.
	public static func paste(
		entities: [EntityClipboard], fileURLs: [URL], into vm: String,
		viewModel: VMListViewModel
	) {
		if !entities.isEmpty {
			EntityClipboard.paste(entities, into: vm, viewModel: viewModel)
		} else {
			_ = handleFileURLs(fileURLs, viewModel: viewModel, vm: vm)
		}
	}
}
