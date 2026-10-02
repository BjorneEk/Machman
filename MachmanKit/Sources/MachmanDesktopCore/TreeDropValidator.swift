//
//  TreeDropValidator.swift
//  MachmanDesktopCore
//
//  What a drop on one of the device tree's sections (Disks, Mounts, Kernel, Initramfs) would
//  add. Every dragged item is judged on its own: the section takes what fits it, and the
//  preview names the first fitting item and says how many it skips (a folder dropped on Disks
//  among disk images). The hover UI (GroupDropDelegate and the preview row) lives in
//  MachmanDesktopUI's TreeDrop.swift. Validation is an extension heuristic — the engine's
//  magic sniff stays the real gate at import.
//

import Foundation
import MachmanAPI

// What a drag currently targets and what we know about its payload.
public struct TreeDragPreview: Equatable {
	public enum Section: Hashable {
		case disks
		case mounts
		case kernel(KernelRole)
	}

	public enum Verdict: Equatable {
		case loading                 // providers still resolving
		case valid(String)           // inline message ("Add vmlinuz to Kernel")
		case invalid(String)         // inline reason ("…is not a supported disk format")
	}

	public var section: Section
	public var urls: [URL] = []
	// What the drop adds: the dragged items that fit the section.
	public var adds: [URL] = []
	public var verdict: Verdict = .loading

	public init(
		section: Section, urls: [URL] = [], adds: [URL] = [], verdict: Verdict = .loading
	) {
		self.section = section
		self.urls = urls
		self.adds = adds
		self.verdict = verdict
	}

	public var isInvalid: Bool {
		if case .invalid = verdict { return true }
		return false
	}

	public static func resolve(
		section: Section, urls: [URL],
		isDirectory: (URL) -> Bool = TreeDropValidator.isDirectory
	) -> TreeDragPreview {
		TreeDragPreview(
			section: section, urls: urls,
			adds: TreeDropValidator.fitting(
				section: section, urls: urls, isDirectory: isDirectory),
			verdict: TreeDropValidator.verdict(
				section: section, urls: urls, isDirectory: isDirectory))
	}
}

public enum TreeDropValidator {
	// Formats the engine's sniff is known to reject — surfaced early with a reason.
	public static let unsupportedDiskExtensions: Set<String> = [
		"qcow2", "qcow", "vdi", "vmdk", "vhd", "vhdx",
	]
	// Same name hints KernelStore uses to infer roles for legacy files.
	public static let initramfsHints = ["initramfs", "initrd", "ramdisk", "rootfs", "cpio"]

	public static func isDirectory(_ url: URL) -> Bool {
		var isDir: ObjCBool = false
		FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
		return isDir.boolValue
	}

	// The dragged items the section takes, in drag order.
	public static func fitting(
		section: TreeDragPreview.Section, urls: [URL],
		isDirectory: (URL) -> Bool = TreeDropValidator.isDirectory
	) -> [URL] {
		urls.filter { misfit($0, section: section, isDirectory: isDirectory) == nil }
	}

	// Valid when anything fits, named after the first fitting item; refused with the first
	// item's reason when nothing does.
	public static func verdict(
		section: TreeDragPreview.Section, urls: [URL],
		isDirectory: (URL) -> Bool = TreeDropValidator.isDirectory
	) -> TreeDragPreview.Verdict {
		guard let first = urls.first else { return .loading }
		let adds = fitting(section: section, urls: urls, isDirectory: isDirectory)
		guard let lead = adds.first else {
			return .invalid(misfit(first, section: section, isDirectory: isDirectory) ?? "")
		}
		let name = lead.lastPathComponent
		let more = adds.count > 1 ? " and \(adds.count - 1) more" : ""
		let skipped = urls.count - adds.count
		let note = skipped > 0 ? " — \(skipped) skipped" : ""
		switch section {
		case .disks:
			let noun = adds.count > 1 ? "disks" : "a disk"
			return .valid("Add \(name)\(more) as \(noun)\(note)")
		case .mounts:
			return .valid("Share \(name)\(more) via virtiofs\(note)")
		case .kernel(let role):
			let looksInitramfs = initramfsHints.contains {
				name.lowercased().contains($0)
			}
			if role == .kernel, looksInitramfs {
				return .valid("Add \(name) to Kernel (name looks like an initramfs)\(note)")
			}
			let target = role == .kernel ? "Kernel" : "Initramfs"
			return .valid("Add \(name)\(more) to \(target)\(note)")
		}
	}

	// Why one item does not fit the section, or nil when it does.
	private static func misfit(
		_ url: URL, section: TreeDragPreview.Section, isDirectory: (URL) -> Bool
	) -> String? {
		switch section {
		case .disks:
			if isDirectory(url) {
				return "Folders mount — they don’t attach as disks"
			}
			if unsupportedDiskExtensions.contains(url.pathExtension.lowercased()) {
				return "\(url.lastPathComponent) is not a supported disk format — "
					+ "raw images and ISOs only"
			}
			return nil
		case .mounts:
			return isDirectory(url) ? nil : "Only folders can be shared as mounts"
		case .kernel(.unknown):
			return "Unknown kernel role"
		case .kernel(let role):
			guard isDirectory(url) else { return nil }
			return role == .kernel
				? "Folders can’t be kernels" : "Folders can’t be initramfs images"
		}
	}
}
