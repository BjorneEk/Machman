//
//  AddFlows+Sections.swift
//  MachmanDesktopCore
//
//  The device tree's sections (Disks, Mounts, Kernel, Initramfs) each take only what fits
//  them, on a drop and on paste alike: disk files share one copy-or-reference question,
//  folders mount under their own names, kernel files promote under their stem.
//

import Foundation
import MachmanAPI

extension EntityClipboard.Kind {
	// The copied entity a section takes; nil for a section no entity fits.
	public init?(section: TreeDragPreview.Section) {
		switch section {
		case .disks: self = .disk
		case .mounts: self = .mount
		case .kernel(.kernel): self = .kernel
		case .kernel(.initramfs): self = .initramfs
		case .kernel: return nil
		}
	}
}

extension AddFlows {
	// Files already known to fit `section` (a validated drop, or paste's fitting files).
	public static func add(
		_ urls: [URL], to section: TreeDragPreview.Section, vm: String,
		viewModel: VMListViewModel
	) {
		switch section {
		case .disks:
			if !urls.isEmpty {
				askDiskReferenceOrCopy(viewModel: viewModel, vm: vm, urls: urls)
			}
		case .mounts:
			for url in urls {
				viewModel.addMount(vm, path: url.path, tag: url.lastPathComponent)
			}
		case .kernel(let role):
			for url in urls {
				viewModel.promoteKernel(
					vm, role: role, sourcePath: url.path,
					tag: KernelTag.suggested(forFile: url.path))
			}
		}
	}

	// Paste into one section: copied entities of its own kind when the clipboard holds
	// any, otherwise the pasteboard's files that fit it (the drop rules).
	public static func paste(
		into section: TreeDragPreview.Section, entities: [EntityClipboard], fileURLs: [URL],
		vm: String, viewModel: VMListViewModel,
		isDirectory: (URL) -> Bool = TreeDropValidator.isDirectory
	) {
		let kind = EntityClipboard.Kind(section: section)
		let matching = entities.filter { $0.kind == kind }
		if !matching.isEmpty {
			EntityClipboard.paste(matching, into: vm, viewModel: viewModel)
			return
		}
		let files = TreeDropValidator.fitting(
			section: section, urls: fileURLs, isDirectory: isDirectory)
		add(files, to: section, vm: vm, viewModel: viewModel)
	}
}
