//
//  VMListViewModel+SaveTerminal.swift
//  MachmanDesktopUI
//
//  File → Save Terminal: the save panel half of the view model's terminal state. The menu
//  saves the key window's terminal (CommandTarget), a torn window's included.
//

import AppKit
import UniformTypeIdentifiers
import MachmanDesktopCore

extension VMListViewModel {
	// Save the main canvas's active terminal transcript.
	public func saveActiveTerminalTranscript() {
		guard let terminal = activeTerminalController else { return }
		saveTerminalTranscript(of: terminal)
	}

	// Save one terminal's transcript through a save panel. Used by File → Save Terminal. The
	// transcript (up to 8 MiB) is taken here, the write to a possibly slow or network volume
	// happens off the main thread (P11).
	public func saveTerminalTranscript(of terminal: any TerminalController) {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "terminal.log"
		panel.allowedContentTypes = [.plainText]
		guard panel.runModal() == .OK, let url = panel.url else { return }
		let transcript = terminal.transcript()
		Task.detached(priority: .userInitiated) { [weak self] in
			do {
				try transcript.write(to: url)
			} catch {
				await self?.present(error, while: "Saving the terminal log")
			}
		}
	}
}
