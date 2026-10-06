//
//  OpenPanelRequest.swift
//  MachmanDesktopCore
//
//  One "choose a file or a folder" question, as the add flows ask it (Q21): what may be
//  picked. AppKit-free: MachmanDesktopUI's OpenPanels asks it with an NSOpenPanel, and a test
//  answers it itself, so a flow's cancel and pick paths run without a panel.
//

import Foundation
import UniformTypeIdentifiers

public struct OpenPanelRequest: Equatable, Sendable {
	public enum Pick: Equatable, Sendable {
		case file, folder
	}

	public let pick: Pick
	// The file types offered; empty for any file.
	public let contentTypes: [UTType]

	public init(pick: Pick, contentTypes: [UTType] = []) {
		self.pick = pick
		self.contentTypes = contentTypes
	}
}
