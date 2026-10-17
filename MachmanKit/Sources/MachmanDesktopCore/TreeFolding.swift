//
//  TreeFolding.swift
//  MachmanDesktopCore
//
//  The device tree's ← and → (H60). Only the Kernel, SSH and Serial labels can be selected,
//  so arrows that folded only a selected label left Disks, Mounts, Installers, Devices and
//  Initramfs out of a keyboard user's reach. As in Finder and Xcode outlines, ← on an entry
//  row folds the group it sits in — the selection stays on the row, as a click on the label
//  leaves it — and → on that row unfolds the group again.
//

import Foundation
import MachmanUI

public enum TreeFolding {
	// The group label an entry row sits under, by the sections' own titles; nil for the
	// root and for the labels themselves.
	public static func group(of node: SidebarNode) -> SidebarNode? {
		let section: TreeSection
		switch node {
		case .vmRoot, .group:
			return nil
		case .disk: section = .disks
		case .mount: section = .mounts
		case .serial: section = .serial
		case .sshSession: section = .ssh
		case .device(let kind): section = kind.isInstaller ? .installers : .devices
		case .kernel: section = .kernel
		case .initramfs: section = .initramfs
		}
		return .group(section.title)
	}

	// The group ← (`open` false) folds or → unfolds with `selection` selected: a selected
	// label itself, or an entry row's group when the key changes it. Nil leaves the key to
	// the List: a multi-selection, the root, nothing to change, or a rename field open (its
	// arrows move the caret).
	public static func target(
		open: Bool, selection: Set<SidebarNode>, expanded: Set<SidebarNode>, renaming: Bool
	) -> SidebarNode? {
		guard !renaming, selection.count == 1, let node = selection.first else { return nil }
		if case .group = node { return node }
		guard let group = group(of: node), expanded.contains(group) != open else { return nil }
		return group
	}
}
