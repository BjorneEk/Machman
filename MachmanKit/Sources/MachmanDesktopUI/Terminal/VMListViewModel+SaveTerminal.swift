//
//  VMListViewModel+SaveTerminal.swift
//  MachmanDesktopUI
//
//  File → Save Terminal: the save panel half of the view model's active-terminal state.
//

import AppKit
import UniformTypeIdentifiers
import MachmanDesktopCore

extension VMListViewModel {
	// Save the on-screen terminal transcript. Used by File → Save Terminal.
	public func saveActiveTerminalTranscript() {
		guard let terminal = activeTerminalController else { return }
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "terminal.log"
		panel.allowedContentTypes = [.plainText]
		if panel.runModal() == .OK, let url = panel.url {
			do {
				try terminal.transcript().write(to: url)
			} catch {
				present(error, while: "Saving the terminal log")
			}
		}
	}
}
