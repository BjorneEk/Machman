//
//  TreeDrop.swift
//  MachmanDesktop
//
//  Role-aware drops onto the device tree's sections (1.0.4 UI): while a drag hovers a
//  group, a would-be entry row renders in it — green when the payload fits the section,
//  red with the reason inline when it doesn't — and sliding the drag between groups moves
//  the preview. Built on DropDelegate (dropDestination can't see the payload mid-hover):
//  dropEntered resolves the file URLs from the item providers so the row can name and
//  validate them, dropUpdated proposes copy/forbidden (the native no-entry cursor), and
//  performDrop routes to the section's add flow. Validation is an extension heuristic —
//  the engine's magic sniff stays the real gate at import.
//

import SwiftUI
import UniformTypeIdentifiers
import MachmanUI
import MachmanAPI

// What a drag currently targets and what we know about its payload.
struct TreeDragPreview: Equatable {
	enum Section: Hashable {
		case disks
		case mounts
		case kernel(KernelRole)
	}

	enum Verdict: Equatable {
		case loading                 // providers still resolving
		case valid(String)           // inline message ("Add vmlinuz to Kernel")
		case invalid(String)         // inline reason ("…is not a supported disk format")
	}

	var section: Section
	var urls: [URL] = []
	var verdict: Verdict = .loading

	var isInvalid: Bool {
		if case .invalid = verdict { return true }
		return false
	}
}

enum TreeDropValidator {
	// Formats the engine's sniff is known to reject — surfaced early with a reason.
	static let unsupportedDiskExtensions: Set<String> = [
		"qcow2", "qcow", "vdi", "vmdk", "vhd", "vhdx",
	]
	// Same name hints KernelStore uses to infer roles for legacy files.
	static let initramfsHints = ["initramfs", "initrd", "ramdisk", "rootfs", "cpio"]

	static func isDirectory(_ url: URL) -> Bool {
		var isDir: ObjCBool = false
		FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
		return isDir.boolValue
	}

	static func verdict(
		section: TreeDragPreview.Section, urls: [URL]
	) -> TreeDragPreview.Verdict {
		guard let first = urls.first else { return .loading }
		let name = first.lastPathComponent
		let isDir = isDirectory(first)
		let suffix = urls.count > 1 ? " and \(urls.count - 1) more" : ""
		switch section {
		case .disks:
			if isDir {
				return .invalid("Folders mount — they don't attach as disks")
			}
			if unsupportedDiskExtensions.contains(first.pathExtension.lowercased()) {
				return .invalid("\(name) is not a supported disk format — "
					+ "raw images and ISOs only")
			}
			return .valid("Add \(name)\(suffix) as a disk")
		case .mounts:
			if !isDir {
				return .invalid("Only folders can be shared as mounts")
			}
			return .valid("Share \(name)\(suffix) via virtiofs")
		case .kernel(let role):
			if isDir {
				return .invalid(role == .kernel
					? "Folders can't be kernels" : "Folders can't be initramfs images")
			}
			let looksInitramfs = initramfsHints.contains {
				name.lowercased().contains($0)
			}
			switch role {
			case .kernel where looksInitramfs:
				return .valid("Add \(name) to Kernel (name looks like an initramfs)")
			case .kernel:
				return .valid("Add \(name)\(suffix) to Kernel")
			case .initramfs:
				return .valid("Add \(name)\(suffix) to Initramfs")
			case .unknown:
				return .invalid("Unknown kernel role")
			}
		}
	}
}

// One drop target per group section. `touched` fires on every enter/update so the owner
// can run an expiry watchdog — AppKit does not reliably deliver dropExited when a drag
// session cancels, which used to strand the preview row in the tree.
struct GroupDropDelegate: DropDelegate {
	let section: TreeDragPreview.Section
	@Binding var preview: TreeDragPreview?
	let touched: () -> Void
	let perform: ([URL]) -> Void

	func validateDrop(info: DropInfo) -> Bool {
		info.hasItemsConforming(to: [.fileURL])
	}

	func dropEntered(info: DropInfo) {
		touched()
		preview = TreeDragPreview(section: section)
		Self.loadURLs(info) { urls in
			// Still hovering this section? (The drag may have moved on meanwhile.)
			guard preview?.section == section, !urls.isEmpty else { return }
			preview = TreeDragPreview(
				section: section, urls: urls,
				verdict: TreeDropValidator.verdict(section: section, urls: urls))
		}
	}

	func dropUpdated(info: DropInfo) -> DropProposal? {
		touched()
		if let preview, preview.section == section, preview.isInvalid {
			return DropProposal(operation: .forbidden)
		}
		return DropProposal(operation: .copy)
	}

	func dropExited(info: DropInfo) {
		if preview?.section == section {
			preview = nil
		}
	}

	func performDrop(info: DropInfo) -> Bool {
		let current = preview
		preview = nil
		if let current, current.section == section {
			if current.isInvalid { return false }
			if !current.urls.isEmpty {
				perform(current.urls)
				return true
			}
		}
		// The hover never finished resolving — resolve now, validate, and route.
		Self.loadURLs(info) { urls in
			guard !urls.isEmpty,
				!TreeDropValidator.verdict(section: section, urls: urls).isInvalidVerdict
			else { return }
			perform(urls)
		}
		return true
	}

	// Resolve the dragged file URLs; results land on the main queue.
	static func loadURLs(_ info: DropInfo, completion: @escaping ([URL]) -> Void) {
		let providers = info.itemProviders(for: [.fileURL])
		guard !providers.isEmpty else {
			completion([])
			return
		}
		var urls: [URL] = []
		let group = DispatchGroup()
		for provider in providers {
			group.enter()
			provider.loadItem(
				forTypeIdentifier: UTType.fileURL.identifier, options: nil
			) { item, _ in
				DispatchQueue.main.async {
					if let data = item as? Data,
						let url = URL(dataRepresentation: data, relativeTo: nil) {
						urls.append(url)
					} else if let url = item as? URL {
						urls.append(url)
					}
					group.leave()
				}
			}
		}
		group.notify(queue: .main) {
			completion(urls)
		}
	}
}

extension TreeDragPreview.Verdict {
	var isInvalidVerdict: Bool {
		if case .invalid = self { return true }
		return false
	}
}

// The would-be entry rendered in the hovered section.
struct TreeDropPreviewRow: View {
	let preview: TreeDragPreview
	let icon: String
	@Environment(\.machmanTheme) private var theme

	private var color: Color { preview.isInvalid ? .red : .green }

	private var title: String {
		guard let first = preview.urls.first else { return "Dropping…" }
		let more = preview.urls.count > 1 ? " +\(preview.urls.count - 1)" : ""
		return first.lastPathComponent + more
	}

	private var message: String {
		switch preview.verdict {
		case .loading: return "Drop to add here"
		case .valid(let text): return text
		case .invalid(let reason): return reason
		}
	}

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: preview.isInvalid ? MachmanSymbols.warning : icon)
				.font(.system(size: theme.metrics.iconSize))
				.foregroundStyle(color)
			VStack(alignment: .leading, spacing: 1) {
				Text(title)
					.font(.system(size: theme.metrics.rowFontSize))
					.lineLimit(1)
					.truncationMode(.middle)
				Text(message)
					.font(.caption2)
					.foregroundStyle(.secondary)
					.lineLimit(2)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer()
		}
		.padding(.vertical, 3)
		.padding(.horizontal, 6)
		.background(RoundedRectangle(cornerRadius: 5, style: .continuous)
			.fill(color.opacity(0.12)))
		.overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
			.strokeBorder(color.opacity(0.5),
				style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
	}
}
