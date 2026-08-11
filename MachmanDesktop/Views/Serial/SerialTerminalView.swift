//
//  SerialTerminalView.swift
//  MachmanDesktop
//
//  A SwiftTerm terminal wired to a serial port's data-plane socket. Guest output is fed to the
//  terminal for display; keystrokes go back down the socket. No termios anywhere — the socket
//  has no line discipline. Resize does not propagate to the guest (the serial console has no
//  window-size channel); use `stty` in the guest for full-screen apps.
//

import SwiftUI
import SwiftTerm

struct SerialTerminalView: NSViewRepresentable {
	let connection: SerialTerminalConnection

	func makeCoordinator() -> Coordinator { Coordinator(connection: connection) }

	func makeNSView(context: Context) -> TerminalView {
		let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
		terminal.terminalDelegate = context.coordinator
		connection.onData = { [weak terminal] data in
			terminal?.feed(byteArray: [UInt8](data)[...])
		}
		return terminal
	}

	func updateNSView(_ nsView: TerminalView, context: Context) {}

	final class Coordinator: NSObject, TerminalViewDelegate {
		let connection: SerialTerminalConnection
		init(connection: SerialTerminalConnection) { self.connection = connection }

		func send(source: TerminalView, data: ArraySlice<UInt8>) {
			connection.send(Data(data))
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
}
