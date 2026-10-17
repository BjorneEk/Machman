//
//  VMListViewModel+SaveTerminal.swift
//  MachmanDesktopUI
//
//  File → Save Terminal: the save panel half of the view model's terminal state. The menu
//  saves the key window's terminal (CommandTarget), a torn window's included. The panel is a
//  sheet on that window, named for the VM and tab (H63) — never the app-modal runModal.
//

import AppKit
import UniformTypeIdentifiers
import MachmanDesktopCore

// Who answers Save Terminal's question: a save sheet on the key window, or a test's answer.
// The answer is the chosen URL, nil for Cancel, delivered on the main actor.
struct SavePanels {
	let save: @MainActor (SavePanelRequest, @escaping @MainActor (URL?) -> Void) -> Void

	static let system = SavePanels { request, answer in
		let panel = NSSavePanel()
		panel.nameFieldStringValue = request.name
		panel.allowedContentTypes = request.contentTypes
		let done: (NSApplication.ModalResponse) -> Void = { response in
			let url = response == .OK ? panel.url : nil
			DispatchQueue.main.async { answer(url) }
		}
		// The window whose menu asked; with none key, a panel of its own (never modal).
		if let window = NSApp.keyWindow {
			panel.beginSheetModal(for: window, completionHandler: done)
		} else {
			panel.begin(completionHandler: done)
		}
	}
}

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
		saveTerminalTranscript(of: terminal, panels: .system)
	}

	func saveTerminalTranscript(of terminal: any TerminalController, panels: SavePanels) {
		panels.save(transcriptSaveRequest(for: terminal)) { [weak self] url in
			guard let self, let url else { return }
			self.writeTerminalTranscript(terminal.transcript(), to: url)
		}
	}

	// The panel's answer written out: off the main thread, a failure as the save's alert.
	// Apart from the panel so a test reaches the write (R3W1-8) without one.
	func writeTerminalTranscript(_ transcript: Data, to url: URL) {
		Task.detached(priority: .userInitiated) { [weak self] in
			do {
				try transcript.write(to: url)
			} catch {
				await self?.present(error, while: "Saving the terminal log")
			}
		}
	}
}
