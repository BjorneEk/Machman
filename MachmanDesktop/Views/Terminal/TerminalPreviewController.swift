//
//  TerminalPreviewController.swift
//  MachmanDesktop
//
//  A throwaway terminal for the settings view's live preview: a SerialTerminalController that is
//  never connected to a socket, fed a canned ANSI sample so the current profile's colours and
//  font can be seen as they are edited. Live settings re-apply in place; a startup-only change
//  (scrollback/convertEol/termName/cursor/tabWidth) recreates the terminal, mirroring what Reload
//  does to a real one.
//

import SwiftUI
import SwiftTerm
import MachmanUI
import MachmanDesktopCore

final class TerminalPreviewController: ObservableObject {
	@Published private(set) var controller: SerialTerminalController
	private var signature: TerminalStartupSignature

	init(profile: TerminalProfile) {
		controller = SerialTerminalController(profile: profile)
		signature = profile.startupSignature
		feed()
	}

	func apply(_ profile: TerminalProfile) {
		if profile.startupSignature != signature {
			controller = SerialTerminalController(profile: profile)
			signature = profile.startupSignature
			feed()
		} else {
			controller.applyLive(profile)
		}
	}

	private func feed() {
		controller.terminalView.feed(byteArray: Array(Self.sample.utf8)[...])
	}

	// A short banner, the 16 palette colours, and a couple of coloured shell-like lines.
	private static let sample: String = {
		let e = "\u{1b}"
		var s = "\r\n  \(e)[1mMachman terminal preview\(e)[0m\r\n\r\n  "
		for i in 0..<8 { s += "\(e)[3\(i)m\u{2588}\u{2588}\(e)[0m" }
		s += "\r\n  "
		for i in 0..<8 { s += "\(e)[9\(i)m\u{2588}\u{2588}\(e)[0m" }
		s += "\r\n\r\n"
		s += "  \(e)[32muser@machman\(e)[0m:\(e)[34m~\(e)[0m$ ls -la\r\n"
		s += "  drwxr-xr-x   3 user  staff   96 kernel/\r\n"
		s += "  \(e)[34mREADME.md\(e)[0m   \(e)[31merror.log\(e)[0m   \(e)[33mvmlinuz\(e)[0m\r\n"
		s += "  \(e)[90m# the quick brown fox jumps over the lazy dog\(e)[0m\r\n"
		return s
	}()
}
