//
//  SerialTerminalView.swift
//  MachmanDesktop
//
//  A SwiftTerm terminal wired to a serial port's data-plane socket. The controller owns ONE
//  persistent TerminalView and connection for the port's lifetime, so switching tabs never
//  reconnects (a reconnect replays the socket's ring buffer, which re-answers the guest's
//  cursor-position queries and leaves stray "…R" escape echoes in the display).
//
//  Guest output is fed to the terminal; keystrokes go back down the socket. No termios anywhere.
//  Resize does not reach the guest (a serial console has no window-size channel) — use `stty` in
//  the guest for full-screen apps.
//

import SwiftUI
import AppKit
import SwiftTerm
import MachmanUI

final class SerialTerminalController: NSObject, ObservableObject, TerminalViewDelegate {
	let terminalView: TerminalView
	private var connection: SerialTerminalConnection?
	@Published var connected = false

	// The startup-only settings baked into terminalView at creation. The info panel compares this
	// against the current profile to decide whether a Reload is needed (font/colours apply live;
	// scrollback/convertEol/termName/cursor/tabWidth cannot change on a live terminal).
	let startupSignature: TerminalStartupSignature

	init(profile: TerminalProfile) {
		startupSignature = profile.startupSignature
		// convertEol: a bare-metal UART emits bare LF with no CR (QEMU's stdio adds it via ONLCR;
		// our raw socket does not), so without it each line staircases. scrollback: a chatty
		// kernel swamps the 500-line default, so profiles default to a deep history.
		let options = TerminalOptions(
			convertEol: profile.convertEol,
			termName: profile.termName,
			cursorStyle: Self.cursorStyle(profile.cursor),
			scrollback: profile.scrollback,
			tabStopWidth: profile.tabStopWidth)
		terminalView = TerminalView(
			frame: CGRect(x: 0, y: 0, width: 800, height: 480), options: options)
		super.init()
		terminalView.terminalDelegate = self
		applyLive(profile)
	}

	// Kept for the legacy per-port detail view until the tabbed pane replaces it; defaults to the
	// built-in OneDark profile.
	convenience override init() {
		self.init(profile: .oneDarkDefault)
	}

	// Re-apply the LIVE settings (font, colours, key/mouse behaviour) to the existing terminal.
	// Safe to call any time; the startup-only settings are ignored here (they need a Reload).
	func applyLive(_ profile: TerminalProfile) {
		let size = CGFloat(profile.fontSize)
		terminalView.font = NSFont(name: profile.fontName, size: size)
			?? NSFont(name: "Menlo", size: size)
			?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
		let c = profile.colors
		if let fg = NSColor(hexColor: c.foreground) { terminalView.nativeForegroundColor = fg }
		if let bg = NSColor(hexColor: c.background) { terminalView.nativeBackgroundColor = bg }
		if let caret = NSColor(hexColor: c.cursor) { terminalView.caretColor = caret }
		terminalView.caretTextColor = c.cursorText.flatMap { NSColor(hexColor: $0) }
		if let sel = NSColor(hexColor: c.selectionBackground) {
			terminalView.selectedTextBackgroundColor = sel
		}
		let palette = c.ansi.compactMap { SwiftTerm.Color.from(hexColor: $0) }
		if palette.count == 16 { terminalView.installColors(palette) }
		terminalView.optionAsMetaKey = profile.optionAsMeta
		terminalView.allowMouseReporting = profile.mouseReporting
	}

	private static func cursorStyle(_ cursor: TerminalCursor) -> CursorStyle {
		switch cursor {
		case .blinkBlock: return .blinkBlock
		case .block: return .steadyBlock
		case .blinkUnderline: return .blinkUnderline
		case .underline: return .steadyUnderline
		case .blinkBar: return .blinkBar
		case .bar: return .steadyBar
		}
	}

	// Idempotent: connect once per socket. A different socket (VM restart) is a new controller.
	func connect(path: String) {
		guard connection == nil else { return }
		let c = SerialTerminalConnection(path: path)
		c.onData = { [weak self] data in
			self?.terminalView.feed(byteArray: [UInt8](data)[...])
		}
		// Clear the connection on close so a VM restart (same socket path) can reconnect.
		c.onClose = { [weak self] in
			self?.connection = nil
			self?.connected = false
		}
		if c.connect() { connection = c; connected = true }
	}

	func disconnect() {
		connection?.stop()
		connection = nil
		connected = false
	}

	func transcript() -> Data { connection?.transcriptData() ?? Data() }

	// MARK: TerminalViewDelegate (called on the main thread by SwiftTerm)
	func send(source: TerminalView, data: ArraySlice<UInt8>) {
		connection?.send(Data(data))
	}
	func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
	func setTerminalTitle(source: TerminalView, title: String) {}
	func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
	func scrolled(source: TerminalView, position: Double) {}
	func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
	func bell(source: TerminalView) {}
	func clipboardCopy(source: TerminalView, content: Data) {}
	func clipboardRead(source: TerminalView) -> Data? { nil }
	func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
	func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// Re-parents the controller's single persistent TerminalView; never recreates it.
struct SerialTerminalHost: NSViewRepresentable {
	let controller: SerialTerminalController

	func makeNSView(context: Context) -> TerminalView { controller.terminalView }
	func updateNSView(_ nsView: TerminalView, context: Context) {}
}
