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
import SwiftTerm

final class SerialTerminalController: NSObject, ObservableObject, TerminalViewDelegate {
	let terminalView: TerminalView
	private var connection: SerialTerminalConnection?
	@Published var connected = false

	override init() {
		// convertEol: a bare-metal UART emits bare LF with no CR (QEMU's stdio adds it via
		// ONLCR; our raw socket does not), so each line would staircase down the screen —
		// convertEol makes the terminal treat LF as CR+LF. scrollback: the default 500 lines is
		// swamped by a chatty kernel, so keep a deep history.
		let options = TerminalOptions(convertEol: true, scrollback: 500_000)
		terminalView = TerminalView(
			frame: CGRect(x: 0, y: 0, width: 800, height: 480), options: options)
		super.init()
		terminalView.terminalDelegate = self
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
