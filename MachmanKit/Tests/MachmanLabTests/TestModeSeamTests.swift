//
//  TestModeSeamTests.swift
//  MachmanLabTests
//
//  L2 — r3-tb's test-mode seams, live: this worktree's Debug agent and the vmhosts it spawns,
//  under the lab's .test-<token> suite. The headless suites prove each seam's decision
//  (TB1–TB13); these prove the real processes take it. A seam whose failure would reach the
//  host (a microphone prompt, a VM window) is exercised only after a harmless sibling has
//  proven the vmhost runs under test mode, in this build, in this run.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import MachmanAPI
import MachmanClient
import MachmanTestSupport

@Suite("Test-mode seams", .serialized, .enabled(if: Lab.runs(.l2)))
struct TestModeSeamTests {
	@Test("Q18: a test-suite agent has no menu bar item, window, Dock icon or focus (TB14)")
	func agentStaysQuiet() async throws {
		try await Lab.withAgent { agent in
			let banner = LabLog.entries().last {
				$0.processID == Int(agent.pid) && $0.eventMessage.contains("test mode: agent")
			}
			let expected = "test mode: agent under \(Lab.suiteID); prompts answered from "
				+ "\(agent.scope.answersPath); control \(agent.scope.controlPath); "
				+ "no menu bar item"
			#expect(banner?.eventMessage.hasSuffix(expected) == true)
			#expect(try await agent.control("ping") == "ok")
			#expect(try await agent.control("menu start nowhere") == "error no VM named nowhere")
			// Long enough for the host audit (0.5 s ticks) to sample the agent a few times.
			try await Task.sleep(for: .seconds(2))
			// A status item is a window of its process, shown or hidden: none at all.
			#expect(SeamProbe.windows(of: agent.pid).isEmpty)
			let app = NSRunningApplication(processIdentifier: agent.pid)
			#expect(app?.activationPolicy == .prohibited)
			#expect(app?.isActive == false)
			#expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != agent.pid)
			#expect(SeamProbe.breaches(naming: [agent.pid]) == [])
		}
	}

	@Test("Q18: a spawned vmhost inherits the test suite and keeps its sockets in it (TB14)")
	func vmhostInheritsSuite() async throws {
		// A variable the agent has and never forwards: whether its vmhost gets it anyway.
		let options = LabAgent.Options(environment: [SeamProbe.agentOnly: "1"])
		try await Lab.withAgent(options) { agent in
			let mark = LabLog.mark()
			try await agent.withVM(LabVMSpec(name: "seam-suite", boot: .alpine())) { vm in
				let host = try await vm.hostPID()
				let env = try await SeamProbe.environment(of: host)
				#expect(env["MACHMAN_SUITE_ID"] == Lab.suiteID)
				#expect(env["CFFIXED_USER_HOME"] == agent.scope.homeDir)
				#expect(env["HOME"] == agent.scope.homeDir)
				#expect(env["MACHMAN_DATA_DIR"] == agent.scope.dataDir)
				#expect(env["MACHMAN_LAB_ANSWERS"] == agent.scope.answersPath)
				#expect(env["MACHMAN_VERSION"] == agent.bundleVersion)
				// spawnHost passes MACHMAN_VERSION and the forwarded set, and counts on that
				// replacing the vmhost's environment; LaunchServices merges it onto the agent's.
				let agentEnv = try await SeamProbe.environment(of: agent.pid)
				try #require(agentEnv[SeamProbe.agentOnly] == "1")
				withKnownIssue(SeamProbe.mergedEnvironmentCard) {
					#expect(env[SeamProbe.agentOnly] == nil)
				}
				let inherits = try await LabLog.waitFor(
					"test mode: vmhost for seam-suite inherits ", after: mark,
					process: "MachmanAgent")
				#expect(inherits.eventMessage.contains("MACHMAN_SUITE_ID"))
				#expect(inherits.eventMessage.contains("CFFIXED_USER_HOME"))
				// Its control socket and its log: the test suite's, by this very process.
				let socket = MachmanPaths.vmSocketPath(vm: vm.name)
				let serving = try await LabLog.waitFor(
					"serving " + NSRegularExpression.escapedPattern(for: socket), after: mark,
					process: "MachmanVMHost")
				#expect(serving.processID == Int(host))
				#expect(serving.subsystem == Lab.suiteID)
				// Its console data plane: tty sockets under the test suite, none under .dev.
				let runtime = SeamProbe.runtimeDir(suite: Lab.suiteID)
				let dev = SeamProbe.runtimeDir(suite: "com.gustaffranzen.Machman.dev")
				for index in 0..<2 {
					let path = try await vm.consoleSocketPath(index)
					let name = (path as NSString).lastPathComponent
					#expect((path as NSString).deletingLastPathComponent == runtime)
					#expect(name.hasPrefix("tty-"))
					#expect(FileManager.default.fileExists(atPath: path))
					#expect(!FileManager.default.fileExists(atPath: dev + "/" + name))
				}
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				#expect(try await console.run("echo seam-$((6*7))").output == "seam-42")
			}
		}
	}

	@Test("Q18: a test-suite vmhost starts without audio and the USB keyboard and pointer (TB14)")
	func devicePolicyDropsAudioAndHID() async throws {
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(
				name: "seam-devices", boot: .alpine(), devices: [.keyboard, .pointer])
			// LabVMSpec refuses audio: the devices go on over the wire, as a person's would.
			try await agent.withVM(spec, start: false) { vm in
				_ = try await agent.api.addDevice(vm: vm.name, kind: .audioOutput)
				var mark = LabLog.mark()
				try await vm.start()
				let host = try await vm.hostPID()
				// The canary: the policy runs in this vmhost (audio output needs no permission).
				let dropped = try await LabLog.waitFor(
					"test mode: seam-devices starts without audio output, keyboard, pointer "
						+ "\\(lab device policy\\)", after: mark, process: "MachmanVMHost")
				try #require(dropped.processID == Int(host))
				// The guest agrees: no virtio sound function on its PCI bus, no input device.
				do {
					let console = try await vm.console(0)
					defer { console.close() }
					try await console.expect("LAB-READY", timeout: .seconds(60))
					let pci = try await console.run(
						"cat /sys/bus/pci/devices/*/device | sort -u | tr '\\n' ' '")
					#expect(pci.status == 0)
					#expect(pci.output.contains("0x1043"))   // virtio console: the bus is read
					#expect(!pci.output.contains("0x1059"))  // virtio sound
					let hid = try await vm.console(1)
					defer { hid.close() }
					let state = try await hid.expect("HID-(READY|NONE)", timeout: .seconds(60))
					#expect(state[1] == "NONE")
				}
				try await vm.stop()
				// Only now the microphone, whose device would ask the user for permission.
				_ = try await agent.api.addDevice(vm: vm.name, kind: .audioInput)
				mark = LabLog.mark()
				try await vm.start()
				let again = try await LabLog.waitFor(
					"test mode: seam-devices starts without audio input, audio output, keyboard, "
						+ "pointer \\(lab device policy\\)", after: mark, process: "MachmanVMHost")
				#expect(again.processID == Int(try await vm.hostPID()))
			}
		}
	}

	@Test("Q18: a test-suite vmhost opens no window and captures no preview (TB14)")
	func vmhostOpensNoWindow() async throws {
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(name: "seam-window", boot: .alpine(), devices: [.graphics])
			try await agent.withVM(spec, start: false) { vm in
				// The canary first: this build's vmhost is under test mode (no window at stake).
				let probe = LabLog.mark()
				try await vm.start()
				let host = try await vm.hostPID()
				let env = try await SeamProbe.environment(of: host)
				try #require(env["MACHMAN_SUITE_ID"] == Lab.suiteID)
				let preview = try await agent.api.preview(vm: vm.name, maxWidth: nil)
				let size = preview.flatMap(SeamProbe.pixelSize)
				#expect(size?.width == 300 && size?.height == 200)   // the black fallback
				_ = try await LabLog.waitFor(
					"test mode: no preview for seam-window under the test suite", after: probe,
					process: "MachmanVMHost")
				try await vm.stop()
				// A windowed start, then the agent menu's Open Window: neither opens one.
				var mark = LabLog.mark()
				try await SeamProbe.startWindowed(vm, on: agent)
				let windowed = try await vm.hostPID()
				let first = try await LabLog.waitFor(
					"test mode: no window for seam-window under the test suite", after: mark,
					process: "MachmanVMHost")
				#expect(first.processID == Int(windowed))
				#expect(try await vm.info().windowOpen == false)
				mark = LabLog.mark()
				#expect(try await SeamProbe.control(agent, "menu openWindow seam-window") == "ok")
				_ = try await LabLog.waitFor(
					"test mode: no window for seam-window under the test suite", after: mark,
					process: "MachmanVMHost")
				#expect(try await agent.control("menu closeWindow seam-window") == "disabled")
				try await Task.sleep(for: .seconds(2))
				#expect(SeamProbe.windows(of: windowed).filter(\.onscreen).isEmpty)
				let app = NSRunningApplication(processIdentifier: windowed)
				#expect(app?.activationPolicy != .regular)
				#expect(app?.isActive == false)
				#expect(SeamProbe.breaches(naming: [agent.pid, windowed]) == [])
			}
		}
	}

	@Test("Q18: under a lab sshd the guest setup payload pins the lab's host key (TB14)")
	func payloadPinsLabSSHD() async throws {
		let keyPath = try #require(Lab.environment["MACHMAN_LAB_SSHD_HOSTKEY"])
		let labKey = try String(contentsOfFile: keyPath, encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		try #require(labKey.hasPrefix("ssh-ed25519 "))
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(name: "seam-setup", boot: .alpine(), devices: [.guestSetup])
			try await agent.withVM(spec) { vm in
				let payload = MachmanPaths.vmsDir(dataDir: agent.scope.dataDir)
					+ "/\(vm.name)/share/GuestSetup"
				let pinned = try String(
					contentsOfFile: payload + "/host_machine_key.pub", encoding: .utf8)
				#expect(pinned.trimmingCharacters(in: .whitespacesAndNewlines) == labKey)
				let system = try? String(
					contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8)
				if let system {
					#expect(system.trimmingCharacters(in: .whitespacesAndNewlines) != labKey)
				}
				// C-2: the pin is the one change; machman.env names no lab sshd.
				let env = try String(contentsOfFile: payload + "/machman.env", encoding: .utf8)
				#expect(env.contains("HOST_USER="))
				#expect(!env.contains("LAB_SSHD"))
				// And the guest reads that pin through its share.
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				let seen = try await console.run(
					"modprobe -q virtiofs; mkdir -p /mnt/h && mount -t virtiofs host-share /mnt/h"
						+ " && cat /mnt/h/GuestSetup/host_machine_key.pub")
				#expect(seen.status == 0)
				#expect(seen.output == labKey)
			}
		}
	}

	@Test("Q18: an agent quit is answered from the answers file, held while it serves (TB14)")
	func quitAnsweredFromFile() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "seam-quit", boot: .alpine())) { vm in
				let host = try await vm.hostPID()
				// Cancel, after 10 s: the prompt is up that long, as a shown alert would be.
				let hold = 10
				try agent.setAnswers([
					"agent.vmsStillRunning": ["button": "Cancel", "holdSeconds": hold],
				])
				var mark = LabLog.mark()
				let asked = ContinuousClock.now
				#expect(try await agent.control("quit") == "ok")
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("agent.vmsStillRunning", "Cancel \\(held 10 s\\)"),
					after: mark, process: "MachmanAgent")
				// Behind the held prompt the daemon serves its socket and its main actor.
				let listed = try await agent.api.listVMs()
				#expect(try await agent.control("ping") == "ok")
				let served = ContinuousClock.now - asked
				#expect(served < .seconds(hold))   // the hold began after `asked`
				#expect(listed.first { $0.name == vm.name }?.state == .running)
				try await Task.sleep(until: asked + .seconds(hold + 2), clock: .continuous)
				#expect(LabProcesses.isAlive(agent.pid))
				#expect(try await agent.control("ping") == "ok")
				// Leave the VMs running: the agent goes, its vmhost stays and serves.
				try agent.setAnswers(["agent.vmsStillRunning": "Quit, Leave VMs Running"])
				mark = LabLog.mark()
				#expect(try await agent.control("quit") == "ok")
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("agent.vmsStillRunning", "Quit, Leave VMs Running$"),
					after: mark, process: "MachmanAgent")
				#expect(await agent.waitForExit(timeout: .seconds(30)))
				#expect(LabProcesses.isAlive(host))
				#expect(try await vm.hostPID() == host)
				// Swept here: the agent that would stop it is gone.
				LabProcesses.signal(host, SIGKILL)
				#expect(await LabProcesses.waitForExit(host, timeout: .seconds(15)))
			}
		}
	}

	@Test("Q18: a lab quit's reason stands in for the quit event's (TB14)")
	func quitReasonFromControl() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "seam-reason", boot: .alpine())) { _ in
				// A log out under a running VM: the agent stays and asks nothing (its VM's
				// window would say why).
				let mark = LabLog.mark()
				#expect(try await agent.control("quit logOut") == "ok")
				_ = try await LabLog.waitFor(
					"logOut canceled: seam-reason still running", after: mark,
					process: "MachmanAgent")
				#expect(LabLog.count("test prompt ", after: mark) == 0)
				#expect(try await agent.control("ping") == "ok")
				// The user's own quit (the default reason): asked, and unlisted takes Cancel.
				let next = LabLog.mark()
				#expect(try await agent.control("quit") == "ok")
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("agent.vmsStillRunning", "Cancel \\(not listed\\)"),
					after: next, process: "MachmanAgent")
				#expect(LabLog.count("canceled: seam-reason", after: next) == 0)
				try await Task.sleep(for: .seconds(1))
				#expect(LabProcesses.isAlive(agent.pid))
				#expect(try await agent.control("ping") == "ok")
			}
		}
	}
}

/// What the tests read of a live lab process: its windows, Dock and focus state, its
/// environment, and the host audit's breaches naming it. Reads only; never acts on a process.
enum SeamProbe {
	/// An agent-only variable: no MACHMAN_LAB_ prefix, so the agent never forwards it.
	static let agentOnly = "MACHMAN_SEAM_AGENT_ONLY"

	/// The draft card for what the agent-only variable shows (wave r3t, r3-tb).
	static let mergedEnvironmentCard = Comment(rawValue: "A vmhost inherits its agent's whole "
		+ "environment: OpenConfiguration.environment merges, it doesn't replace")

	struct Window: Equatable {
		let number: Int
		let layer: Int
		let onscreen: Bool
	}

	/// Every window `pid` owns, on screen or not (the host audit's own read).
	static func windows(of pid: pid_t) -> [Window] {
		let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
			as? [[String: Any]] ?? []
		return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map {
			Window(
				number: $0[kCGWindowNumber as String] as? Int ?? 0,
				layer: $0[kCGWindowLayer as String] as? Int ?? 0,
				onscreen: $0[kCGWindowIsOnscreen as String] as? Bool ?? false)
		}
	}

	/// The audit's breach lines so far (report/watch/watch.jsonl) that name one of `pids`.
	static func breaches(naming pids: Set<pid_t>) -> [String] {
		let path = Lab.runDir + "/report/watch/watch.jsonl"
		let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
		return text.split(separator: "\n").compactMap { line in
			guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
				as? [String: Any], object["level"] as? String == "breach",
				let pid = object["pid"] as? Int, pids.contains(pid_t(pid)) else { return nil }
			return String(line)
		}
	}

	/// The environment `ps -E` shows for `pid`: its KEY=value words after the command.
	static func environment(of pid: pid_t) async throws -> [String: String] {
		let result = try await Subprocess.run("/bin/ps", ["-Eww", "-o", "command=", "-p", "\(pid)"])
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "ps -E -p \(pid)", status: result.status, output: result.output)
		}
		var values: [String: String] = [:]
		for word in result.output.split(whereSeparator: \.isWhitespace) {
			guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { continue }
			let key = word[..<equals]
			guard key.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isUppercase || $0.isNumber)) })
			else { continue }
			values[String(key)] = String(word[word.index(after: equals)...])
		}
		return values
	}

	/// `$TMPDIR/<suite>`, as MachmanPaths.runtimeDir derives it for that suite.
	static func runtimeDir(suite: String) -> String {
		MachmanPaths.runtimeDir(env: ["MACHMAN_SUITE_ID": suite])
	}

	static func pixelSize(_ jpeg: Data) -> (width: Int, height: Int)? {
		guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
				as? [CFString: Any],
			let width = properties[kCGImagePropertyPixelWidth] as? Int,
			let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
		return (width, height)
	}

	/// `test prompt <id>: "<message>" → <answer>`, as a pattern.
	static func promptLine(_ id: String, _ answer: String) -> String {
		"test prompt " + NSRegularExpression.escapedPattern(for: id) + ": \".*\" \u{2192} "
			+ answer
	}

	/// A control line repeated until it answers `ok`: the agent menu lists a VM's new state
	/// a moment after the VM reaches it. Any other final answer is returned as is.
	static func control(
		_ agent: LabAgent, _ line: String, timeout: Duration = .seconds(15)
	) async throws -> String {
		let deadline = ContinuousClock.now + timeout
		while true {
			let answer = try await agent.control(line)
			if answer == "ok" || ContinuousClock.now >= deadline { return answer }
			try await Task.sleep(for: .milliseconds(250))
		}
	}

	/// LabVM.start, but asking for the VM's window as a person's start does.
	static func startWindowed(_ vm: LabVM, on agent: LabAgent) async throws {
		let running = LabProcesses.liveGuestCount()
		if running >= 2 { throw LabError.guestCap(running: running) }
		try await agent.api.start(vm: vm.name, options: StartOptions(openWindow: true))
		try await vm.waitForState(.running, timeout: .seconds(90))
		try LabProcesses.writePid(
			try await vm.hostPID(), kind: "vmhost", name: "\(agent.scope.id)-\(vm.name)")
	}
}
