//
//  EntityClipboard.swift
//  MachmanDesktop
//
//  Copyable tree entities on the general pasteboard: a disk, kernel, or initramfs file
//  (by path) or a mount (path + tag). The JSON payload rides a custom pasteboard type,
//  with the plain path as a string for interop; pasting into a VM funnels through the
//  same flows as every other entry point (disk copy-or-reference, kernel promote,
//  mount re-share).
//

import AppKit
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

	static let pasteboardType = NSPasteboard.PasteboardType(
		"com.gustaffranzen.machman.entity")

	// MARK: - Pasteboard (the payload is a LIST — multi-selections copy together)

	static func write(_ items: [EntityClipboard]) {
		guard !items.isEmpty else { return }
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		if let data = try? JSONEncoder().encode(items) {
			pasteboard.setData(data, forType: pasteboardType)
		}
		pasteboard.setString(
			items.map(\.path).joined(separator: "\n"), forType: .string)
	}

	static func write(_ item: EntityClipboard) {
		write([item])
	}

	static func read() -> [EntityClipboard] {
		guard let data = NSPasteboard.general.data(forType: pasteboardType) else {
			return []
		}
		if let items = try? JSONDecoder().decode([EntityClipboard].self, from: data) {
			return items
		}
		// A single-item payload from an older build.
		if let item = try? JSONDecoder().decode(EntityClipboard.self, from: data) {
			return [item]
		}
		return []
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
