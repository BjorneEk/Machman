//
//  EngineSSHSessionTests.swift
//  MachmanLabTests
//
//  L2 — an ssh session tab, as the desktop runs it: the app's TerminalSessions starting
//  /usr/bin/ssh on a pty (PTYProcessStream) with the product's argv, into the lab sshd on
//  127.0.0.1 (T12/T23: the guest's sshd is the lab's, so R3 moved here from L3). A closed tab
//  or a dead app leaves no ssh behind (T5b), the pty follows resizes across a reconnect
//  (P20), a key the server doesn't know shows ssh's own password prompt (P20), and
//  Reconnect keeps the scrollback behind a marker (R3).
//

import Foundation
import Testing
import MachmanAPI
import MachmanUI
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI
@testable import MachmanUI

@Suite("Engine — ssh sessions", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineSSHSessionTests {
	/// Card P42: PTYChild opens the pty's slave in a posix_spawn file action and
	/// relies on that open to make it the child's controlling terminal; on macOS it doesn't
	/// (a probe: `ps -o tty=` shows "??" for the spawned ssh; forkpty's TIOCSCTTY does). So
	/// ssh can't open /dev/tty for a password prompt, and a hung-up pty (the app quitting or
	/// crashing) sends it no SIGHUP: the session and its ssh stay.
	// The open bug P42 (an ssh session tab's ssh has no controlling terminal: no password
	// prompt, and ssh outlives an app that quits or crashes) fails three checks below until
	// it is fixed.

	struct Session {
		let sessions: TerminalSessions
		let target: TFSSHTarget
		let ref: SSHSessionRef
		let controller: SerialTerminalController
		let profile: TerminalProfile
	}

	/// A session tab on a fresh target, its shell answering.
	static func open(
		_ sshd: LabSSHD, authorized: Bool = true, waitForShell: Bool = true
	) async throws -> Session {
		let dir = Lab.runDir + "/tfssh/" + UUID().uuidString.prefix(8)
		let target = try await TFSSHTarget.make(sshd: sshd, dir: dir, authorized: authorized)
		let sessions = TFTerminals.sessions()
		let profile = TFTerminals.profile(dir: dir)
		let ref = SSHSessionRef(title: "\(LabSSHD.macUser)@127.0.0.1")
		sessions.ensureSSHController(
			vm: TFSSHTarget.vmName, ref: ref, arguments: try target.arguments(),
			profile: profile)
		let c = try await TFTerminals.ssh(sessions, vm: TFSSHTarget.vmName, ref: ref)
		if waitForShell {
			TFTerminals.type(c, "echo TF-$((40+2))\n")
			try await TFTerminals.waitFor(c, "^TF-42", timeout: .seconds(20))
		}
		return Session(
			sessions: sessions, target: target, ref: ref, controller: c, profile: profile)
	}

	/// TFWait.until, with what the lab sshd and the ssh clients of `key` look like on a miss.
	static func until(
		_ what: String, key: String, timeout: Duration, _ check: () async throws -> Bool
	) async throws {
		do {
			try await TFWait.until(what, timeout: timeout, check)
		} catch TFError.timeout {
			throw TFError.timeout(what + "\n" + (await TFSSH.describe(key: key)))
		}
	}

	/// The session's raw bytes so far, control characters spelled out (for a failure).
	static func rawTranscript(_ c: SerialTerminalController) -> String {
		String(decoding: c.transcript(), as: UTF8.self).unicodeScalars.map {
			guard $0.value < 0x20, $0 != "\n" else { return String($0) }
			return "^" + String(Character(UnicodeScalar($0.value + 0x40)!))
		}.joined()
	}

	/// `stty size` as the session's shell reports it, read back as "rows cols".
	static func sttySize(_ s: Session, _ tag: String) async throws -> String {
		TFTerminals.type(s.controller, "echo \(tag)-$(stty size | tr ' ' x)\n")
		let hit = try await TFTerminals.waitFor(
			s.controller, "^\(tag)-[0-9]+x[0-9]+", timeout: .seconds(10))
		return String(hit.dropFirst(tag.count + 1)).replacingOccurrences(of: "x", with: " ")
	}

	@Test("T5b: closing a session tab leaves no ssh process behind")
	func closedTabLeavesNoSSH() async throws {
		let quiet = HostQuiet.baseline()
		try await LabSSHD.with { sshd in
			let s = try await Self.open(sshd)
			#expect(!(try await TFSSH.clientPIDs(key: s.target.keyPath)).isEmpty)
			#expect(!(try await TFSSH.sshdSessions()).isEmpty)
			s.sessions.drop(.ssh(s.ref), vm: TFSSHTarget.vmName)
			try await Self.until(
				"the ssh client and its session to end", key: s.target.keyPath,
				timeout: .seconds(10)
			) {
				let clients = try await TFSSH.clientPIDs(key: s.target.keyPath)
				let servers = try await TFSSH.sshdSessions()
				return clients.isEmpty && servers.isEmpty
			}
		}
		#expect(HostQuiet.breaches(since: quiet) == [])
	}

	@Test("T5b: an ssh session ends when its pty's owner lets go")
	func hangUpEndsSession() async throws {
		try await LabSSHD.with { sshd in
			let dir = Lab.runDir + "/tfssh/" + UUID().uuidString.prefix(8)
			let target = try await TFSSHTarget.make(sshd: sshd, dir: dir)
			var env = ProcessInfo.processInfo.environment
			env["SSH_AUTH_SOCK"] = nil
			env["TERM"] = "xterm-256color"
			let spawned = PTYChild.spawn(
				executablePath: "/usr/bin/ssh", arguments: try target.arguments(),
				environment: env, size: nil, onExit: {})
			let (child, master) = try #require(spawned)
			var closed = false
			defer {
				if !closed { close(master) }
				if LabProcesses.isAlive(child.pid) { kill(child.pid, SIGKILL) }
			}
			try await Self.until("the remote session", key: target.keyPath, timeout: .seconds(20)) {
				!(try await TFSSH.sshdSessions()).isEmpty
			}
			// The shell answers (a session tab past its login, as the app's would be).
			let reader = Task { await offPool { () -> String in
				var seen = Data()
				var buffer = [UInt8](repeating: 0, count: 4096)
				let deadline = Date().addingTimeInterval(15)
				while Date() < deadline {
					var poll = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
					guard Darwin.poll(&poll, 1, 200) > 0 else { continue }
					let n = Darwin.read(master, &buffer, buffer.count)
					if n <= 0 { break }
					seen.append(contentsOf: buffer[0..<n])
					if String(decoding: seen, as: UTF8.self).contains("TF-42") { break }
				}
				return String(decoding: seen, as: UTF8.self)
			} }
			_ = "echo TF-$((40+2))\n".utf8CString.withUnsafeBufferPointer {
				Darwin.write(master, $0.baseAddress, $0.count - 1)
			}
			let seen = await reader.value
			try #require(seen.contains("TF-42"), "the session's shell never answered: \(seen)")
			// The pty is ssh's controlling terminal (what a hang-up and /dev/tty need).
			let tty = try await TFProcess.controllingTTY(child.pid)
			// Fails until the open bug P42 (ssh has no controlling terminal) is fixed.
			#expect(tty.hasPrefix("ttys"), "ssh's controlling terminal is \(tty)")
			// What the kernel does for an app that exits: its pty master closes, no signal.
			close(master)
			closed = true
			do {
				try await Self.until(
					"the ssh client and its session to end", key: target.keyPath,
					timeout: .seconds(10)
				) {
					let servers = try await TFSSH.sshdSessions()
					return !LabProcesses.isAlive(child.pid) && servers.isEmpty
				}
			} catch {
				// Fails until the open bug P42 (ssh outlives its pty's owner) is fixed.
				Issue.record(Comment(rawValue: "\(error)"))
			}
		}
	}

	@Test("W2-41: stty size follows the terminal's resizes and a reconnect")
	func sttySizeFollowsResizes() async throws {
		let quiet = HostQuiet.baseline()
		try await LabSSHD.with { sshd in
			let s = try await Self.open(sshd)
			let terminal = s.controller.terminalView.getTerminal()
			#expect(try await Self.sttySize(s, "SZ1") == "\(terminal.rows) \(terminal.cols)")
			s.controller.terminalView.resize(cols: 100, rows: 30)
			try await Task.sleep(for: .milliseconds(500))
			#expect(try await Self.sttySize(s, "SZ2") == "30 100")
			TFTerminals.type(s.controller, "exit\n")
			try await TFWait.until("the session to end", timeout: .seconds(10)) {
				!s.controller.connected
			}
			s.sessions.reconnectSSHSession(
				vm: TFSSHTarget.vmName, ref: s.ref, arguments: try s.target.arguments(),
				profile: s.profile)
			#expect(s.controller.connected)
			try await TFTerminals.waitFor(s.controller, "reconnected", timeout: .seconds(5))
			#expect(try await Self.sttySize(s, "SZ3") == "30 100")
			s.sessions.drop(.ssh(s.ref), vm: TFSSHTarget.vmName)
		}
		#expect(HostQuiet.breaches(since: quiet) == [])
	}

	@Test("W2-42: without a usable key the session shows ssh's password prompt")
	func passwordPromptOnPTY() async throws {
		try await LabSSHD.with(password: true) { sshd in
			let s = try await Self.open(sshd, authorized: false, waitForShell: false)
			// Recorded, not thrown, so the session is dropped below.
			do {
				// Fails until the open bug P42 (no password prompt without a tty) is fixed.
				try await TFTerminals.waitFor(s.controller, "[Pp]assword:", timeout: .seconds(20))
			} catch {
				let described = await TFSSH.describe(key: s.target.keyPath)
				// Fails until the open bug P42 (no password prompt without a tty) is fixed.
				Issue.record(Comment(rawValue: "ssh's password prompt never came; the session's "
					+ "bytes:\n" + Self.rawTranscript(s.controller) + "\n" + described))
			}
			// Fails until the open bug P42 (ssh gives up without a tty) is fixed.
			#expect(s.controller.connected)
			s.sessions.drop(.ssh(s.ref), vm: TFSSHTarget.vmName)
			try await TFWait.until("the ssh client to end", timeout: .seconds(5)) {
				try await TFSSH.clientPIDs(key: s.target.keyPath).isEmpty
			}
		}
	}

	@Test("R3: Reconnect keeps a session's scrollback behind a reconnected line")
	func reconnectKeepsScrollback() async throws {
		let quiet = HostQuiet.baseline()
		try await LabSSHD.with { sshd in
			let s = try await Self.open(sshd)
			TFTerminals.type(s.controller, "echo TF-BEFORE-$((40+2))\n")
			try await TFTerminals.waitFor(s.controller, "^TF-BEFORE-42", timeout: .seconds(10))
			let tree = try await TFSSH.sessionPIDs()
			let killed = try await TFSSH.signalSessions(SIGKILL)
			try #require(!killed.isEmpty)
			do {
				try await TFWait.until("the session to drop", timeout: .seconds(10)) {
					!s.controller.connected
				}
			} catch {
				let alive = tree.filter { LabProcesses.isAlive($0) }
				let clients = try await TFSSH.clientPIDs(key: s.target.keyPath)
				var sockets = ""
				for pid in clients {
					sockets += (try? await Subprocess.run(
						"/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-i"]))?.output ?? ""
				}
				throw TFError.timeout("""
					the session to drop: killed \(killed) of \(tree); still alive \(alive); \
					ssh clients \(clients); their sockets:
					\(sockets)
					\(await TFSSH.describe(key: s.target.keyPath))
					""")
			}
			s.sessions.reconnectSSHSession(
				vm: TFSSHTarget.vmName, ref: s.ref, arguments: try s.target.arguments(),
				profile: s.profile)
			TFTerminals.type(s.controller, "echo TF-AFTER-$((40+2))\n")
			try await TFTerminals.waitFor(s.controller, "^TF-AFTER-42", timeout: .seconds(20))
			#expect(TFTerminals.positions(
				s.controller, ["TF-BEFORE-42", "— reconnected", "TF-AFTER-42"]) != nil)
			#expect(s.sessions.sshTerminal(vm: TFSSHTarget.vmName, ref: s.ref) === s.controller)
			s.sessions.drop(.ssh(s.ref), vm: TFSSHTarget.vmName)
		}
		#expect(HostQuiet.breaches(since: quiet) == [])
	}
}
