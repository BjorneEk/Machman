//
//  EngineFloodTests.swift
//  MachmanLabTests
//
//  L2 — the desktop's terminal under load, measured in the test process that runs the app's
//  own terminal stack: `yes` flooding a console tab and an ssh tab (P29) leaves the main actor
//  answering and memory flat, and ^C stops it; a multi-megabyte paste into an ssh session
//  whose server is frozen (P5) never blocks the main actor and arrives whole, in order, once
//  it resumes. The ssh server is the lab sshd on 127.0.0.1; SIGSTOP reaches only its own
//  sshd-session children, each with a SIGCONT in a defer.
//

import CryptoKit
import Foundation
import Testing
import MachmanAPI
import MachmanUI
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

@Suite("Engine — floods", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineFloodTests {
	/// Draft card (r3-tf): while `yes` floods a Linux guest's console, no input reaches the
	/// guest's shell: ^C, and any command after it, through the tab or a second connection to
	/// the same console socket, stays unanswered until the VM stops (3 of 3 runs, 1 and 2
	/// vCPUs). Over ssh the same ^C stops it at once. Where input stalls (the vmhost's serial
	/// bridge, VZ's virtio console or the guest's hvc driver) is not yet known.
	static let consoleInputUnderFloodCard = Comment(rawValue: "A console flooded with output "
		+ "takes no input: ^C never stops `yes` there")

	/// `yes` into `c` for 10 s: the main actor's largest gap and the footprint's growth from
	/// 3 s to 10 s, then ^C.
	static func flood(_ c: SerialTerminalController) async throws
		-> (gap: Duration, growth: Int64) {
		let probe = TFMainActorProbe()
		probe.start()
		TFTerminals.type(c, "yes\n")
		try await Task.sleep(for: .seconds(3))
		let early = Int64(TFProcess.footprintBytes())
		try await Task.sleep(for: .seconds(7))
		let late = Int64(TFProcess.footprintBytes())
		let gap = probe.stop()
		TFTerminals.type(c, "\u{03}")
		return (gap, late - early)
	}

	/// After the ^C: how long until a command answers. A marker is typed every 2 s (its
	/// output can be lost while the flood's backlog still fills the console's client queue);
	/// nil when none answers within `budget`.
	static func stopped(_ c: SerialTerminalController, budget: Duration) async -> Duration? {
		let began = ContinuousClock.now
		var n = 0
		while ContinuousClock.now - began < budget {
			n += 1
			TFTerminals.type(c, "echo YES-STOP-$((\(n)+1000))\n")
			if (try? await TFTerminals.waitFor(c, "^YES-STOP-10[0-9]+", timeout: .seconds(2)))
				!= nil {
				return ContinuousClock.now - began
			}
		}
		return nil
	}

	@Test(
		"""
		R3W1-5: yes in a console keeps the main actor responsive and memory flat, and ^C \
		stops it
		""")
	func consoleFlood() async throws {
		let quiet = HostQuiet.baseline()
		let sessions = TFTerminals.sessions()
		try await Lab.withAgent { agent in
			// Two vCPUs, as a person's VM has: one leaves the guest's tty input to the vCPU
			// `yes` keeps busy.
			let spec = LabVMSpec(name: "p29", boot: .alpine(), cpus: 2)
			try await agent.withVM(spec) { vm in
				let ref = SerialPortRef(kind: .console, index: 0)
				sessions.ensureController(
					vm: vm.name, ref: ref, socketPath: try await vm.consoleSocketPath(0),
					profile: TFTerminals.profile(dir: agent.scope.dir + "/desktop/p29"))
				let c = try await TFTerminals.serial(sessions, vm: vm.name, ref: ref)
				try await TFTerminals.waitFor(c, "LAB-READY", timeout: .seconds(60))
				let (gap, growth) = try await Self.flood(c)
				#expect(gap < .seconds(1))
				#expect(growth < 64 << 20)
				let took = await Self.stopped(c, budget: .seconds(30))
				var direct: String?
				if took == nil {
					// Whether the guest takes input at all now, past the app's terminal.
					let console = try await vm.console(0)
					defer { console.close() }
					try console.sendRaw([0x03])
					direct = (try? await console.run("echo DIRECT-OK", timeout: .seconds(10)))?
						.output
				}
				withKnownIssue(Self.consoleInputUnderFloodCard) {
					#expect(took != nil, """
						no command answered within 30 s of the ^C; a direct console then \
						\(direct == nil ? "got no answer either" : "answered")
						""")
					#expect((took ?? .seconds(99)) < .seconds(10))
				}
				sessions.drop(.terminal(ref), vm: vm.name)
			}
		}
		#expect(HostQuiet.breaches(since: quiet) == [])
	}

	@Test("R3W1-5: yes over ssh keeps the main actor responsive and memory flat, and ^C stops it")
	func sshFlood() async throws {
		let quiet = HostQuiet.baseline()
		try await LabSSHD.with { sshd in
			let s = try await EngineSSHSessionTests.open(sshd)
			let (gap, growth) = try await Self.flood(s.controller)
			#expect(gap < .seconds(1))
			#expect(growth < 64 << 20)
			let took = await Self.stopped(s.controller, budget: .seconds(30))
			#expect(took != nil, "no command answered within 30 s of the ^C")
			#expect((took ?? .seconds(99)) < .seconds(10))
			s.sessions.drop(.ssh(s.ref), vm: TFSSHTarget.vmName)
		}
		#expect(HostQuiet.breaches(since: quiet) == [])
	}

	/// 4 MiB of base64 lines from a seeded generator (the same bytes every run).
	static func pasteBytes(count: Int) -> [UInt8] {
		var state: UInt64 = 0x9E37_79B9_7F4A_7C15
		var raw = [UInt8](repeating: 0, count: count / 4 * 3)
		for index in raw.indices {
			state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
			raw[index] = UInt8(truncatingIfNeeded: state >> 33)
		}
		var text = Array(Data(raw).base64EncodedString(options: [.lineLength76Characters])
			.replacingOccurrences(of: "\r\n", with: "\n").utf8)
		if text.count > count { text.removeLast(text.count - count) }
		while text.count < count { text.append(UInt8(ascii: "\n")) }
		return text
	}

	@Test("W2-40: a multi-megabyte paste into a stopped sshd arrives in order after it resumes")
	func pasteIntoStoppedServer() async throws {
		let quiet = HostQuiet.baseline()
		try await LabSSHD.with { sshd in
			let s = try await Self.open(sshd)
			let size = 4 << 20
			let file = sshd.home + "/tf-paste.bin"
			try? FileManager.default.removeItem(atPath: file)
			TFTerminals.type(
				s.controller,
				"stty raw -echo; head -c \(size) > \"$HOME/tf-paste.bin\"; stty sane; "
					+ "echo PASTE-DONE-$((40+2))\n")
			try await Task.sleep(for: .seconds(1))
			let stopped = try await TFSSH.signalSessions(SIGSTOP)
			try #require(!stopped.isEmpty)
			var resumed = false
			defer { if !resumed { for pid in stopped { kill(pid, SIGCONT) } } }
			let paste = Self.pasteBytes(count: size)
			let probe = TFMainActorProbe()
			probe.start()
			s.controller.send(source: s.controller.terminalView, data: paste[...])
			try await Task.sleep(for: .seconds(3))
			let gap = probe.stop()
			#expect(gap < .seconds(1))
			for pid in stopped { kill(pid, SIGCONT) }
			resumed = true
			try await TFTerminals.waitFor(s.controller, "^PASTE-DONE-42", timeout: .seconds(30))
			let written = try Data(contentsOf: URL(fileURLWithPath: file))
			#expect(written.count == size)
			#expect(SHA256.hash(data: written) == SHA256.hash(data: Data(paste)))
			s.sessions.drop(.ssh(s.ref), vm: TFSSHTarget.vmName)
		}
		#expect(HostQuiet.breaches(since: quiet) == [])
	}

	static func open(_ sshd: LabSSHD) async throws -> EngineSSHSessionTests.Session {
		try await EngineSSHSessionTests.open(sshd)
	}
}
