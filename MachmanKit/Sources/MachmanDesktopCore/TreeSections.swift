//
//  TreeSections.swift
//  MachmanDesktopCore
//
//  The device tree's sections and which of them show (N1). A section with rows always shows.
//  Without a filter, an empty section shows only when the tree is where its things are
//  added: SSH (its + opens a session), Kernel and Initramfs (their files come only from the
//  tree: its Add From Disk…, drops and paste; Kernel also carries the no-kernel warning).
//  Disks, Mounts, Serial, Installers and Devices are all added from the toolbar's +, so an
//  empty one hides. While a filter is active, a section without a matching row hides. Also
//  here: the VM-derived rows the tree and the selection prune share.
//

import Foundation
import MachmanAPI

public enum TreeSection: CaseIterable, Sendable {
	case disks, mounts, serial, ssh, installers, devices, kernel, initramfs

	// The group's title in the tree (and the text a filter can match to show it whole).
	public var title: String {
		switch self {
		case .disks: return "Disks"
		case .mounts: return "Mounts"
		case .serial: return "Serial"
		case .ssh: return "SSH"
		case .installers: return "Installers"
		case .devices: return "Devices"
		case .kernel: return "Kernel"
		case .initramfs: return "Initramfs"
		}
	}

	// Whether an empty section stays: the tree is the only place to add its things.
	public var staysWhenEmpty: Bool {
		switch self {
		case .ssh, .kernel, .initramfs: return true
		case .disks, .mounts, .serial, .installers, .devices: return false
		}
	}

	// `rows` is what the section would list (after the filter); `filtering` is false when no
	// filter is active, or when the filter matches the section's title (it shows whole).
	public static func isVisible(_ section: TreeSection, rows: Int, filtering: Bool) -> Bool {
		rows > 0 || (!filtering && section.staysWhenEmpty)
	}

	// Whether a shown section's label carries a chevron (N2): only when there is something
	// to fold — its rows, or the would-be row of a drag hovering it. An empty one is a leaf.
	public static func folds(rows: Int, previewing: Bool) -> Bool {
		rows > 0 || previewing
	}
}

// One row of the Kernel or Initramfs section: an owned file, or the active setting when it
// points outside the owned set (an external reference — promotable).
public struct KernelTreeEntry: Identifiable, Equatable, Sendable {
	public let id: String        // absolute path (OwnedKernelFile.id)
	public let label: String     // tag, or file name for external references
	public let owned: Bool
	public let active: Bool

	public init(id: String, label: String, owned: Bool, active: Bool) {
		self.id = id
		self.label = label
		self.owned = owned
		self.active = active
	}
}

extension VMInfo {
	// Console ports, then UART ports: the Serial section's rows.
	public var allSerialPorts: [SerialPortInfo] {
		(consolePorts ?? []) + (uartPorts ?? [])
	}

	// Kernel sections appear once kernel boot is (or was) configured — the draft survives
	// toggling back to EFI, shown parked (dimmed) until kernel boot is on again.
	public var showsKernelSections: Bool {
		boot.mode != .macOS && (boot.kernel != nil || !(boot.ownedKernels ?? []).isEmpty)
	}

	public var kernelSectionParked: Bool { boot.mode != .linuxKernel }

	// Owned files of the role, plus the active settings path when it points outside the
	// owned set.
	public func kernelTreeEntries(role: KernelRole) -> [KernelTreeEntry] {
		let owned = (boot.ownedKernels ?? []).filter { $0.role == role }
		let activePath = role == .kernel ? boot.kernel?.kernelPath : boot.kernel?.initrdPath
		var entries = owned.map {
			KernelTreeEntry(id: $0.path, label: $0.tag, owned: true, active: $0.path == activePath)
		}
		if let activePath, !activePath.isEmpty,
			!owned.contains(where: { $0.path == activePath }) {
			entries.append(KernelTreeEntry(
				id: activePath, label: (activePath as NSString).lastPathComponent,
				owned: false, active: true))
		}
		return entries
	}
}
