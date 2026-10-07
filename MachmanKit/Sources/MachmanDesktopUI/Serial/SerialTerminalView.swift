//
//  SerialTerminalView.swift
//  MachmanDesktopUI
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
import MachmanDesktopCore

final class SerialTerminalController: NSObject, ObservableObject, TerminalViewDelegate {
	let terminalView: TerminalView
	private var connection: TerminalByteStream?
	@Published var connected = false
	// When the terminal lost its connection, or first failed to get one: a tab mounted again
	// later (torn off, switched back to) counts its banner's grace from here, not from its mount.
	// A monotonic clock, so a system clock set back can't stretch the grace.
	private(set) var disconnectedAt: ContinuousClock.Instant?
	// Which container is currently responsible for showing this terminal. There is only
	// ever ONE TerminalView, and SwiftUI can update a mount that is on its way out AFTER
	// its replacement has adopted the view — tearing a tab into its own window does
	// exactly that — so the outgoing mount must not re-adopt and drag the terminal into a
	// container that is about to leave the hierarchy.
	fileprivate weak var mountedIn: ThrottledResizeContainer?
	// The last connection, kept when it closes (VM stop, daemon bounce) so File → Save
	// Terminal can still save what is on screen: its transcript is joined only if asked (P39).
	// A reconnect starts fresh.
	private var lastStream: TerminalByteStream?
	// What applyLive last set, so a repeat sets nothing.
	private var appliedLive: TerminalLiveSettings?
	// A serial terminal's socket. Its bridge closes a terminal that fell 1 MiB behind the
	// guest's output and goes on serving (E58), so a connection that ends while the socket
	// still takes one was this terminal's own: it rejoins (see rejoin()).
	private var servedPath: String?

	// The startup-only settings baked into terminalView at creation. The info panel compares this
	// against the current profile to decide whether a Reload is needed (font/colours apply live;
	// scrollback/convertEol/termName/cursor/tabWidth cannot change on a live terminal).
	let startupSignature: TerminalStartupSignature

	init(profile: TerminalProfile) {
		startupSignature = profile.startupSignature
		// convertEol: a bare-metal UART emits bare LF with no CR (QEMU's stdio adds it via ONLCR;
		// our raw socket does not), so without it each line staircases. scrollback: a chatty
		// kernel swamps SwiftTerm's 500-line default, so profiles keep 10,000 lines (bounded:
		// a deeper history slows every resize, and Save Terminal writes its own 8 MiB).
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

	// Re-apply the LIVE settings (font, colours, key/mouse behaviour) to the existing terminal.
	// Safe to call any time; the startup-only settings are ignored here (they need a Reload).
	// Only what changed since the last call is set: SwiftTerm's font setter drops the glyph
	// caches and the selection, and the colour setters redraw the whole screen (P38).
	func applyLive(_ profile: TerminalProfile) {
		let live = profile.liveSettings
		let last = appliedLive
		appliedLive = live
		if live.fontName != last?.fontName || live.fontSize != last?.fontSize {
			let size = CGFloat(live.fontSize)
			terminalView.font = TerminalFonts.font(named: live.fontName, size: size)
		}
		if live.colors != last?.colors {
			applyColors(live.colors)
		}
		if live.optionAsMeta != last?.optionAsMeta {
			terminalView.optionAsMetaKey = live.optionAsMeta
		}
		if live.mouseReporting != last?.mouseReporting {
			terminalView.allowMouseReporting = live.mouseReporting
		}
	}

	private func applyColors(_ c: TerminalColors) {
		if let fg = NSColor(hexColor: c.foreground) { terminalView.nativeForegroundColor = fg }
		if let bg = NSColor(hexColor: c.background) { terminalView.nativeBackgroundColor = bg }
		if let caret = NSColor(hexColor: c.cursor) { terminalView.caretColor = caret }
		terminalView.caretTextColor = c.cursorText.flatMap { NSColor(hexColor: $0) }
		if let sel = NSColor(hexColor: c.selectionBackground) {
			terminalView.selectedTextBackgroundColor = sel
		}
		let palette = c.ansi.compactMap { SwiftTerm.Color.from(hexColor: $0) }
		if palette.count == 16 { terminalView.installColors(palette) }
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
		servedPath = path
		connect(stream: SerialTerminalConnection(path: path))
	}

	// The generalized seam: any TerminalByteStream (serial socket, PTY-backed ssh).
	func connect(stream: TerminalByteStream) {
		guard connection == nil else { return }
		let c = stream
		c.onData = { [weak self] data in
			self?.terminalView.feed(byteArray: [UInt8](data)[...])
		}
		// Clear the connection on close so a VM restart (same socket path) can reconnect.
		// `weak c` (not captured strongly — that would cycle through onClose) is alive here:
		// the closing stream is the one invoking us.
		c.onClose = { [weak self, weak c] in
			guard let self else { return }
			if let c { self.lastStream = c }
			self.connection = nil
			if self.rejoin() { return }
			self.disconnectedAt = .now
			self.connected = false
		}
		// The terminal's current size is the new session's first size: a reconnect, or a
		// view that already has its final frame, sends no resize of its own.
		let terminal = terminalView.getTerminal()
		c.setWindowSize(cols: terminal.cols, rows: terminal.rows)
		if c.connect() {
			connection = c
			lastStream = nil
			disconnectedAt = nil
			connected = true
		} else if disconnectedAt == nil {
			disconnectedAt = .now   // a failed retry keeps the first failure's time
		}
	}

	// E58: the bridge closed this terminal for falling 1 MiB behind and still serves (a stopped
	// port's socket is gone before its terminals see the end). The terminal starts over from
	// the bridge's replay of recent output, cleared first so nothing it showed shows twice.
	// Called as the connection ends; false when nothing serves the socket any more.
	private func rejoin() -> Bool {
		guard let path = servedPath else { return false }
		connect(stream: SerialTerminalConnection(path: path))
		guard connection != nil else { return false }
		// The replay reaches the terminal on a later main-queue turn: the reset lands first.
		terminalView.getTerminal().resetToInitialState()
		note("reconnected after falling behind "
			+ Date().formatted(date: .omitted, time: .shortened))
		return true
	}

	// Machman's own line in the guest's terminal — session boundaries, nothing else. CRLF
	// on both sides so it starts at column 0 whatever the guest left behind.
	func note(_ text: String) {
		let line = "\r\n\u{1b}[2m— \(text) —\u{1b}[0m\r\n"
		terminalView.feed(byteArray: [UInt8](Array(line.utf8))[...])
	}

	// Only TerminalSessions calls this, and only to throw the controller away (tab closed,
	// port or VM gone, Reload), so nothing is kept for Save Terminal.
	func disconnect() {
		connection?.stop()
		connection = nil
		lastStream = nil
		connected = false
	}

	func transcript() -> Data { (connection ?? lastStream)?.transcriptData() ?? Data() }

	// MARK: TerminalViewDelegate (called on the main thread by SwiftTerm)
	func send(source: TerminalView, data: ArraySlice<UInt8>) {
		connection?.send(Data(data))
	}
	func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
		connection?.setWindowSize(cols: newCols, rows: newRows)
	}
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

// In an extension, not the class declaration: a conformance there would infer the protocol's
// @MainActor onto the whole class.
extension SerialTerminalController: TerminalController {}

extension TerminalSessions {
	// The app's registry: every terminal tab gets a SwiftTerm-backed controller.
	public static func swiftTerm() -> TerminalSessions {
		TerminalSessions { SerialTerminalController(profile: $0) }
	}

	// The SwiftTerm controllers behind a tab, for the views that host their TerminalView.
	func serialTerminal(vm: String, ref: SerialPortRef) -> SerialTerminalController? {
		controller(vm: vm, ref: ref) as? SerialTerminalController
	}

	func sshTerminal(vm: String, ref: SSHSessionRef) -> SerialTerminalController? {
		sshController(vm: vm, ref: ref) as? SerialTerminalController
	}
}

// Re-parents the controller's single persistent TerminalView; never recreates it. The
// newest mount owns it (tearing a tab off makes the window's container before SwiftUI has
// finished removing the canvas's), and older mounts keep their hands off.
struct SerialTerminalHost: NSViewRepresentable {
	let controller: SerialTerminalController

	// Remembers which controller this mount was made for, so the dying mount can hand
	// ownership back (see dismantleNSView).
	final class Coordinator {
		weak var controller: SerialTerminalController?
		init(_ controller: SerialTerminalController) { self.controller = controller }
	}

	func makeCoordinator() -> Coordinator { Coordinator(controller) }

	func makeNSView(context: Context) -> ThrottledResizeContainer {
		let container = ThrottledResizeContainer()
		controller.mountedIn = container
		container.adopt(controller.terminalView)
		return container
	}

	func updateNSView(_ nsView: ThrottledResizeContainer, context: Context) {
		// An outgoing mount would otherwise steal the terminal back on its way out.
		guard controller.mountedIn === nsView else { return }
		nsView.adopt(controller.terminalView)
	}

	static func dismantleNSView(_ nsView: ThrottledResizeContainer, coordinator: Coordinator) {
		if coordinator.controller?.mountedIn === nsView {
			coordinator.controller?.mountedIn = nil
		}
		nsView.releaseChildIfOwned()
	}
}
