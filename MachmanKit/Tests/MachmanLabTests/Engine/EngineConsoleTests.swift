//
//  EngineConsoleTests.swift
//  MachmanLabTests
//
//  L2 — a VM's console as the desktop's console tab and its log file see it: the log keeps
//  its contents across a Max size change (E25), a paste nobody reads is dropped with one log
//  line while output keeps flowing (E18), a stopped VM's tab keeps the last session's
//  transcript (P39), and a killed vmhost's tab disconnects and reconnects on the same
//  controller with a marker (T25). The tab is the app's own SwiftTerm controller
//  (TerminalSessions.swiftTerm), never in a window (TFTerminals).
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanUI
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

@Suite("Engine — consoles", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineConsoleTests {
	static let console0 = SerialPortRef(kind: .console, index: 0)

	static func size(_ path: String) -> UInt64 {
		((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?
			.uint64Value ?? 0
	}

	@Test("W1-23: changing Max size keeps a reset-on-boot log's contents")
	func maxSizeKeepsLog() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "e25", boot: .alpine())) { vm in
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				let log = TFVM.dir(agent, vm.name) + "/serial-console0.log"
				try await TFWait.until("the console log", timeout: .seconds(10)) {
					((try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
						.contains("LAB-READY")
				}
				let before = try Data(contentsOf: URL(fileURLWithPath: log))
				try await agent.api.setSerialLogging(
					vm: vm.name, kind: .console, index: 0,
					config: SerialLogConfig(mode: .resetOnBoot, maxBytes: 1 << 20))
				_ = try await console.run("echo TF-RETUNE-$((40+2))")
				try await TFWait.until("the retuned log's new line", timeout: .seconds(10)) {
					((try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
						.contains("TF-RETUNE-42")
				}
				let after = try Data(contentsOf: URL(fileURLWithPath: log))
				#expect(after.starts(with: before))
				#expect(after.count > before.count)
			}
		}
	}

	@Test("W1-24: a paste into a console nobody reads drops with one log line while output flows")
	func unreadPasteDrops() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "e18", boot: .alpine())) { vm in
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				_ = try await console.run("true")
				let mark = LabLog.mark()
				// The shell stops reading for 15 s: nothing takes the paste but the buffers.
				try console.send("stty -echo; sleep 15; echo LAB-AFTER-$((40+2))")
				try await Task.sleep(for: .milliseconds(500))
				let line = Array(String(repeating: "#", count: 78).utf8) + [0x0A]
				let lines = (2 << 20) / line.count
				let paste = Array([[UInt8]](repeating: line, count: lines).joined())
				// Blocking writes, on a thread of their own (never the cooperative pool).
				let sent = Task { await offPool { (try? console.sendRaw(paste)) != nil } }
				let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
					group.addTask { await sent.value }
					group.addTask {
						try await Task.sleep(for: .seconds(30))
						return false
					}
					let first = try await group.next() ?? false
					group.cancelAll()
					return first
				}
				if !finished { console.close() }
				#expect(finished, "the 2 MiB paste didn't go through in 30 s")
				_ = try await LabLog.waitFor(
					"serial console0: guest not reading input, dropping it", after: mark,
					process: "MachmanVMHost", timeout: .seconds(20))
				try await console.expect("LAB-AFTER-42", timeout: .seconds(30))
				#expect(LabLog.count("guest not reading input, dropping it", after: mark) == 1)
				#expect(try await vm.info().state == .running)
			}
		}
	}

	@Test("R3W1-7: a stopped VM's console tab keeps the last session's transcript")
	func stoppedTabKeepsTranscript() async throws {
		let quiet = HostQuiet.baseline()
		let sessions = TFTerminals.sessions()
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent, terminals: sessions)
			try await agent.withVM(LabVMSpec(name: "p39", boot: .alpine())) { vm in
				let socket = try await vm.consoleSocketPath(0)
				var canvas = desktop.canvases.canvas(for: vm.name)
				canvas.open(.terminal(Self.console0))
				desktop.canvases.setCanvas(canvas, for: vm.name)
				let profile = TFTerminals.profile(dir: agent.scope.dir + "/desktop/p39")
				sessions.ensureController(
					vm: vm.name, ref: Self.console0, socketPath: socket, profile: profile)
				let c = try await TFTerminals.serial(sessions, vm: vm.name, ref: Self.console0)
				try await TFTerminals.waitFor(c, "LAB-READY", timeout: .seconds(60))
				TFTerminals.type(c, "echo P39-$((40+2))\n")
				try await TFTerminals.waitFor(c, "^P39-42", timeout: .seconds(10))
				try await vm.stop()
				try await TFWait.until("the tab to disconnect", timeout: .seconds(10)) {
					!c.connected
				}
				try await desktop.waitForEntry("p39", "stopped", timeout: .seconds(10)) {
					$0.state == .stopped
				}
				let kept = try #require(sessions.serialTerminal(vm: vm.name, ref: Self.console0))
				#expect(kept === c)
				let transcript = String(decoding: kept.transcript(), as: UTF8.self)
				#expect(transcript.contains("P39-42"))
			}
			await desktop.close()
		}
		#expect(HostQuiet.breaches(since: quiet) == [])
	}

	@Test(
		"""
		R3W1-9: a killed vmhost's console tab disconnects within a second and reconnects \
		with a marker
		""")
	func killedHostReconnects() async throws {
		let quiet = HostQuiet.baseline()
		let sessions = TFTerminals.sessions()
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "t25", boot: .alpine())) { vm in
				let profile = TFTerminals.profile(dir: agent.scope.dir + "/desktop/t25")
				sessions.ensureController(
					vm: vm.name, ref: Self.console0, socketPath: try await vm.consoleSocketPath(0),
					profile: profile)
				let c = try await TFTerminals.serial(sessions, vm: vm.name, ref: Self.console0)
				try await TFTerminals.waitFor(c, "LAB-READY", timeout: .seconds(60))
				TFTerminals.type(c, "echo BEFORE-$((40+2))\n")
				try await TFTerminals.waitFor(c, "^BEFORE-42", timeout: .seconds(10))
				let host = try await vm.hostPID()
				try #require(TFProcess.killLabApp(host))
				let killed = ContinuousClock.now
				try await TFWait.until("the tab to disconnect", timeout: .seconds(3),
					every: .milliseconds(50)) { !c.connected }
				#expect(ContinuousClock.now - killed < .seconds(3))
				#expect(c.disconnectedAt != nil)
				TFVM.forget(agent, vm.name)
				try await vm.waitForState(.stopped, timeout: .seconds(30))
				// Reconnect while nothing serves: still disconnected, and no marker.
				sessions.reconnectSerial(
					vm: vm.name, ref: Self.console0,
					socketPath: TFVM.dir(agent, vm.name) + "/gone.sock")
				#expect(!c.connected)
				#expect(!TFTerminals.text(c).contains("reconnected"))
				try await vm.start()
				let socket = try await vm.consoleSocketPath(0)
				sessions.reconnectSerial(vm: vm.name, ref: Self.console0, socketPath: socket)
				#expect(c.connected)
				#expect(sessions.serialTerminal(vm: vm.name, ref: Self.console0) === c)
				try await TFWait.until("a new boot after the marker", timeout: .seconds(60)) {
					TFTerminals.positions(c, ["BEFORE-42", "— reconnected", "LAB-READY"]) != nil
				}
			}
		}
		#expect(HostQuiet.breaches(since: quiet) == [])
	}
}
