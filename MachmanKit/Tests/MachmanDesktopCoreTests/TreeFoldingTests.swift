//
//  TreeFoldingTests.swift
//  MachmanDesktopCoreTests
//
//  H60: ← and → folded only the three group labels that can be selected (Kernel, SSH,
//  Serial), so a keyboard user couldn't fold Disks, Mounts, Installers, Devices or
//  Initramfs. Now ← on an entry row folds the group it sits in and → unfolds it again, as
//  Finder and Xcode outlines do; a group label still folds itself; an open rename field
//  keeps its arrows. The key wiring is VMDeviceTreeView's (manual row: no key events
//  offscreen).
//

import Testing
import MachmanAPI
import MachmanUI
@testable import MachmanDesktopCore

struct TreeFoldingTests {
	private static let all: Set<SidebarNode> = Set(TreeSection.allCases.map { .group($0.title) })

	private static func target(
		_ open: Bool, _ selection: Set<SidebarNode>, expanded: Set<SidebarNode> = all,
		renaming: Bool = false
	) -> SidebarNode? {
		TreeFolding.target(
			open: open, selection: selection, expanded: expanded, renaming: renaming)
	}

	@Test("H60: ← on a disk row folds Disks and → unfolds it")
	func theLeftArrowFoldsADisksGroup() {
		let disk: Set<SidebarNode> = [.disk("storage:system")]
		#expect(Self.target(false, disk) == .group("Disks"))
		var folded = Self.all
		folded.remove(.group("Disks"))
		// Folded already: ← has nothing left to do; → brings the row back.
		#expect(Self.target(false, disk, expanded: folded) == nil)
		#expect(Self.target(true, disk, expanded: folded) == .group("Disks"))
		#expect(Self.target(true, disk) == nil)
		// A selected group label folds and unfolds itself, as before.
		#expect(Self.target(false, [.group("Kernel")]) == .group("Kernel"))
		#expect(Self.target(true, [.group("Kernel")], expanded: []) == .group("Kernel"))
		// The root and a multi-selection aren't the arrows' to fold.
		#expect(Self.target(false, [.vmRoot]) == nil)
		#expect(Self.target(false, disk.union([.mount("m")])) == nil)
		#expect(Self.target(false, []) == nil)
	}

	@Test("H60: every entry row folds the group the tree draws it under")
	func eachRowFoldsItsOwnGroup() {
		let console = SerialPortRef(kind: .console, index: 0)
		let rows: [(SidebarNode, String)] = [
			(.disk("storage:system"), "Disks"), (.mount("m"), "Mounts"),
			(.serial(console), "Serial"), (.sshSession(SSHSessionRef(title: "Session 1")), "SSH"),
			(.device(.guestSetup), "Installers"), (.device(.keyboard), "Devices"),
			(.kernel("/k/vmlinuz"), "Kernel"), (.initramfs("/k/initrd.img"), "Initramfs"),
		]
		for (row, group) in rows {
			#expect(TreeFolding.group(of: row) == .group(group), "\(row)")
			#expect(Self.all.contains(.group(group)), "\(group) isn't a tree section")
		}
		#expect(TreeFolding.group(of: .vmRoot) == nil)
		#expect(TreeFolding.group(of: .group("Disks")) == nil)
	}

	@Test("H60: the arrows leave the groups alone while a rename is open")
	func aRenameKeepsItsArrows() {
		#expect(Self.target(false, [.disk("storage:system")], renaming: true) == nil)
		#expect(Self.target(false, [.group("Kernel")], renaming: true) == nil)
	}
}
