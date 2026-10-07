//
//  EntityClipboard.swift
//  MachmanDesktopCore
//
//  Copyable tree entities: a disk, kernel, or initramfs file (by path) or a mount (path +
//  tag). Pasting into a VM funnels through the same flows as every other entry point (disk
//  copy-or-reference, kernel promote, mount re-share). The general-pasteboard I/O lives
//  beside the views (EntityClipboard+Pasteboard.swift in MachmanDesktopUI).
//

import Foundation
import MachmanAPI

public struct EntityClipboard: Codable {
	public enum Kind: String, Codable {
		case disk
		case kernel
		case initramfs
		case mount
	}

	public var kind: Kind
	public var path: String
	public var tag: String?

	public init(kind: Kind, path: String, tag: String? = nil) {
		self.kind = kind
		self.path = path
		self.tag = tag
	}

	// MARK: - Paste routing

	public var fileName: String { (path as NSString).lastPathComponent }

	private var defaultTag: String { KernelTag.suggested(forFile: path) }

	// Paste entities into a VM through the same funnels as the picker and drop entry points;
	// the disks among them share one copy-or-reference question.
	@MainActor
	public static func paste(
		_ items: [EntityClipboard], into vm: String, viewModel: VMListViewModel
	) {
		var disks: [URL] = []
		for item in items {
			switch item.kind {
			case .disk:
				disks.append(URL(fileURLWithPath: item.path))
			case .kernel:
				viewModel.promoteKernel(
					vm, role: .kernel, sourcePath: item.path, tag: item.defaultTag)
			case .initramfs:
				viewModel.promoteKernel(
					vm, role: .initramfs, sourcePath: item.path, tag: item.defaultTag)
			case .mount:
				viewModel.addMount(vm, path: item.path, tag: item.tag ?? item.fileName)
			}
		}
		if !disks.isEmpty {
			AddFlows.askDiskReferenceOrCopy(viewModel: viewModel, vm: vm, urls: disks)
		}
	}
}
