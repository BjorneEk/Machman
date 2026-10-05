//
//  TFTerminals.swift
//  MachmanLabTests
//
//  The app's own terminal stack in the test process: TerminalSessions.swiftTerm() making the
//  SwiftTerm-backed SerialTerminalController the desktop uses, over a console socket or an
//  ssh PTY. Its TerminalView is an NSView, so OffscreenHost.prepare() runs first (NSApp is
//  the host-quiet application, policy .prohibited); a view is never put in a window, and
//  SwiftTerm's copy, paste and link actions are never invoked (no pasteboard, no
//  NSWorkspace). Each test ends with HostQuiet.breaches(since:) empty.
//

import AppKit
import Foundation
import MachmanAPI
import MachmanUI
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

@MainActor
enum TFTerminals {
	/// The app's terminal registry, after the host-quiet NSApp is in place.
	static func sessions() -> TerminalSessions {
		OffscreenHost.prepare()
		return TerminalSessions.swiftTerm()
	}

	static func profile(dir: String) -> TerminalProfile {
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return TerminalProfileStore(
			fileURL: URL(fileURLWithPath: dir).appendingPathComponent("Profiles.json"))
			.defaultProfile
	}

	/// The console tab's controller once TerminalSessions made it (a later main-queue turn).
	static func serial(
		_ sessions: TerminalSessions, vm: String, ref: SerialPortRef
	) async throws -> SerialTerminalController {
		var found: SerialTerminalController?
		try await TFWait.until("\(vm)'s console controller", timeout: .seconds(10)) {
			found = sessions.serialTerminal(vm: vm, ref: ref)
			return found != nil
		}
		return found!
	}

	static func ssh(
		_ sessions: TerminalSessions, vm: String, ref: SSHSessionRef
	) async throws -> SerialTerminalController {
		var found: SerialTerminalController?
		try await TFWait.until("\(vm)'s ssh controller", timeout: .seconds(10)) {
			found = sessions.sshTerminal(vm: vm, ref: ref)
			return found != nil
		}
		return found!
	}

	/// What the terminal shows: its buffer, scrollback included, one line per row.
	static func text(_ c: SerialTerminalController) -> String {
		String(decoding: c.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
	}

	/// Polls the buffer (every 100 ms) for `pattern`; returns the matched text.
	@discardableResult
	static func waitFor(
		_ c: SerialTerminalController, _ pattern: String, timeout: Duration
	) async throws -> String {
		let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
		var hit: String?
		do {
			try await TFWait.until("/\(pattern)/ in the terminal", timeout: timeout,
				every: .milliseconds(100)) {
				let text = Self.text(c)
				guard let match = regex.firstMatch(
					in: text, range: NSRange(text.startIndex..., in: text)) else { return false }
				hit = (text as NSString).substring(with: match.range)
				return true
			}
		} catch {
			throw TFError.timeout("/\(pattern)/ in the terminal; it shows:\n"
				+ String(text(c).suffix(1500)))
		}
		return hit!
	}

	/// Types `text` the way a key press does (the controller's send, the TerminalView path).
	static func type(_ c: SerialTerminalController, _ text: String) {
		c.send(source: c.terminalView, data: ArraySlice(Array(text.utf8)))
	}

	/// The order the given substrings first appear in the terminal's text (nil when one is
	/// missing): proves "earlier output, then the marker, then new output".
	static func positions(_ c: SerialTerminalController, _ parts: [String]) -> [Int]? {
		let text = Self.text(c)
		var result: [Int] = []
		var from = text.startIndex
		for part in parts {
			guard let range = text.range(of: part, range: from..<text.endIndex) else { return nil }
			result.append(text.distance(from: text.startIndex, to: range.lowerBound))
			from = range.upperBound
		}
		return result
	}
}
