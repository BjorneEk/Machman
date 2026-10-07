//
//  ConsoleStallTests.swift
//  MachmanLabTests
//
//  L3 — E58's repro. Once in a full parallel run a Debian console showed its prompt and then
//  echoed nothing typed into it for five minutes. This loops console sessions on the Debian
//  fixture, a few commands each, under whatever load the run's other shards bring. Every
//  session's end makes the vmhost log its console's counts (SerialPortBridge, E58): input
//  typed, taken by the guest, waiting and dropped; the guest's output; and what the session
//  got and lost. A missed echo is a stall, noted on the test with those counts, so a run tells
//  input lost in the bridge from a guest that stopped reading and from output a slow client
//  never got.
//

import Foundation
import Testing

@Suite("L3 consoles under load", .serialized, .enabled(if: Lab.runs(.l3)))
struct ConsoleStallTests {
	static let sessions = 30
	static let commands = 10

	/// One "serial console2 counts: …; client got …, lost …" line of the vmhost's.
	struct Counts {
		var typed: UInt64 = 0
		var taken: UInt64 = 0
		var waiting: UInt64 = 0
		var dropped: UInt64 = 0
		var got: UInt64 = 0
		var lost: UInt64 = 0

		init?(_ line: String) {
			func value(_ key: String) -> UInt64? {
				guard let range = line.range(of: #"\b\#(key) [0-9]+"#, options: .regularExpression)
				else { return nil }
				return UInt64(line[range].dropFirst(key.count + 1))
			}
			guard let typed = value("typed"), let taken = value("taken"),
				let waiting = value("waiting"), let dropped = value("dropped"),
				let got = value("got"), let lost = value("lost") else { return nil }
			(self.typed, self.taken, self.waiting, self.dropped) = (typed, taken, waiting, dropped)
			(self.got, self.lost) = (got, lost)
		}
	}

	/// A new session on the logged-in shell of hvc2: its first echo also ends the replay of
	/// what earlier sessions saw.
	static func attach(_ vm: LabVM, session: Int) async throws -> LabConsole {
		let console = try await LabConsole.connect(
			try await vm.consoleSocketPath(2), transcript: "console-loop-hvc2-s\(session)",
			title: "console-loop hvc2 session \(session)")
		try console.send("echo 'E58''ATTACH\(session)'")
		try await console.expect("^E58ATTACH\(session)$", timeout: .seconds(20))
		return console
	}

	@Test("E58: console sessions on Debian lose no input in the bridge and no output to a client")
	func sessionsLoseNothing() async throws {
		try await Lab.withAgent { agent in
			let image = try await LabGuest.debian.imagePath()
			let vm = try await LabVM.create(
				LabVMSpec(
					name: "console-loop", boot: .efiImagePath(image), cpus: 2, memoryGiB: 2,
					consolePorts: 3),
				on: agent)
			let first = try await vm.bootLoggedIn(2, label: "hvc2")
			var stalls = 0
			var lost: UInt64 = 0
			for session in 1...Self.sessions {
				let mark = LabLog.mark()
				var stalled: String?
				var console: LabConsole?
				do {
					let current = session == 1 ? first : try await Self.attach(vm, session: session)
					console = current
					for command in 1...Self.commands {
						let marker = "E58-\(session)-\(command)"
						let ran = try await current.run(
							"echo '\(marker.prefix(4))''\(marker.dropFirst(4))'",
							timeout: .seconds(20))
						if ran.output != marker {
							stalled = "command \(command) printed \(ran.output.debugDescription)"
							break
						}
					}
				} catch let error as LabError {
					stalled = "\(error)"
				}
				console?.close()
				let line = try await LabLog.waitFor(
					"serial console2 counts: .*client got", after: mark, process: "MachmanVMHost",
					timeout: .seconds(20)
				).eventMessage
				let counts = try #require(Counts(line), "unreadable counts: \(line)")
				#expect(counts.typed == counts.taken + counts.waiting + counts.dropped,
					"input lost inside the bridge: \(line)")
				lost += counts.lost
				if let stalled {
					stalls += 1
					LabRetry.note("console-loop session \(session) stalled (\(stalled)): \(line)")
				} else if counts.lost > 0 {
					LabRetry.note("console-loop session \(session) lost output: \(line)")
				}
				if stalls >= 3 { break }
			}
			#expect(lost == 0, "sessions lost \(lost) bytes of the guest's output")
		}
	}
}
