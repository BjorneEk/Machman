//
//  Finder.swift
//  MachmanDesktopUI
//
//  Show in Finder, the one way (Q12): the tree's menus and the inspectors' path rows reveal a
//  file through it.
//

import AppKit

enum Finder {
	static func reveal(_ path: String) {
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
	}
}
