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
import MachmanUI

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
	// the disks among them share one copy-or-reference question. A macOS VM takes no kernel
	// file (its kernel sections only remove, D31): those are skipped, and a toast says so —
	// the tree's background Paste and Edit ▸ Paste both land here (D31, review F20).
	@MainActor
	public static func paste(
		_ items: [EntityClipboard], into vm: String, viewModel: VMListViewModel
	) {
		let removeOnly = viewModel.vms.first { $0.name == vm }?.kernelSectionsRemoveOnly == true
		var disks: [URL] = []
		var skipped = 0
		for item in items {
			switch item.kind {
			case .disk:
				disks.append(URL(fileURLWithPath: item.path))
			case .kernel where removeOnly, .initramfs where removeOnly:
				skipped += 1
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
		if skipped > 0 {
			viewModel.pushToast(
				symbol: MachmanSymbols.info, message: skippedKernels(skipped, vm: vm))
		}
	}

	public static func skippedKernels(_ count: Int, vm: String) -> String {
		let files = count == 1 ? "a kernel file" : "\(count) kernel files"
		return "Skipped \(files) — \(vm) is a macOS VM"
	}
}
