//
//  TreeDrop.swift
//  MachmanDesktopUI
//
//  Role-aware drops onto the device tree's sections (1.0.4 UI): while a drag hovers a
//  group, a would-be entry row renders in it — green when the payload fits the section,
//  red with the reason inline when it doesn't — and sliding the drag between groups moves
//  the preview. Built on DropDelegate (dropDestination can't see the payload mid-hover):
//  dropEntered resolves the file URLs from the item providers so the row can name and
//  validate them, dropUpdated proposes copy/forbidden (the native no-entry cursor), and
//  performDrop routes what fits to the section's add flow. The verdict itself
//  (TreeDropValidator) lives in MachmanDesktopCore.
//

import SwiftUI
import UniformTypeIdentifiers
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

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
			preview = TreeDragPreview.resolve(section: section, urls: urls)
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
			if !current.adds.isEmpty {
				perform(current.adds)
				return true
			}
		}
		// The hover never finished resolving — resolve now and route what fits.
		Self.loadURLs(info) { urls in
			let adds = TreeDropValidator.fitting(section: section, urls: urls)
			guard !adds.isEmpty else { return }
			perform(adds)
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

// The would-be entry rendered in the hovered section.
struct TreeDropPreviewRow: View {
	let preview: TreeDragPreview
	let icon: String
	@Environment(\.machmanTheme) private var theme

	private var color: Color { preview.isInvalid ? MachmanColors.problem : MachmanColors.accepted }

	// Names what the drop adds; a refused drop names what was dragged.
	private var title: String {
		let shown = preview.adds.isEmpty ? preview.urls : preview.adds
		guard let first = shown.first else { return "Dropping…" }
		let more = shown.count > 1 ? " +\(shown.count - 1)" : ""
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
