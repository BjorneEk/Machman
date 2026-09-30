//
//  EntityClipboard.swift
//  MachmanDesktop
//
//  Copyable tree entities: a disk, kernel, or initramfs file (by path) or a mount (path +
//  tag). Pasting into a VM funnels through the same flows as every other entry point (disk
//  copy-or-reference, kernel promote, mount re-share). The general-pasteboard I/O lives
//  beside the views (Views/EntityClipboard+Pasteboard.swift).
//

import Foundation
import MachmanAPI

struct EntityClipboard: Codable {
	enum Kind: String, Codable {
		case disk
		case kernel
		case initramfs
		case mount
	}

	var kind: Kind
	var path: String
	var tag: String?

	init(kind: Kind, path: String, tag: String? = nil) {
		self.kind = kind
		self.path = path
		self.tag = tag
	}

	// MARK: - Paste routing

	var fileName: String { (path as NSString).lastPathComponent }

	private var defaultTag: String {
		URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
	}

	// Paste this entity into a VM: the same funnels as picker/drop entry points.
	@MainActor
	func paste(into vm: String, viewModel: VMListViewModel) {
		switch kind {
		case .disk:
			AddFlows.askDiskReferenceOrCopy(
				viewModel: viewModel, vm: vm, url: URL(fileURLWithPath: path))
		case .kernel:
			viewModel.promoteKernel(vm, role: .kernel, sourcePath: path, tag: defaultTag)
		case .initramfs:
			viewModel.promoteKernel(vm, role: .initramfs, sourcePath: path, tag: defaultTag)
		case .mount:
			viewModel.addMount(vm, path: path, tag: tag ?? fileName)
		}
	}
}
