//
//  LabSmokeTests.swift
//  MachmanLabTests
//
//  L2 smoke — the lab agent and the Alpine fixture end to end; lab.sh --quick runs it.
//  L3 smoke — the Debian fixture (prepared) under VZ; lab.sh --full and --guests run it.
//  Needs r3-tb's seams in the build: lab.sh refuses the agent tiers without them.
//

import Foundation
import Testing
import MachmanAPI

@Suite("Lab smoke", .serialized, .enabled(if: Lab.runs(.smoke)))
struct LabSmokeTests {
	@Test("Q18: the lab agent answers hello under the test suite")
	func agentAnswersHello() async throws {
		try await Lab.withAgent { agent in
			#expect(agent.api.hello.daemonVersion == agent.bundleVersion)
			#expect(agent.api.peerPID == agent.pid)
			#expect(agent.socketPath == NSTemporaryDirectory() + Lab.suiteID + "/machman.sock")
			#expect(FileManager.default.fileExists(atPath: agent.socketPath))
			#expect(LabLog.count("test mode: agent under") >= 1)
			let vms = try await agent.api.listVMs()
			#expect(vms.isEmpty)
		}
	}

	@Test("Q18: an Alpine fixture boots to LAB-READY on hvc0")
	func alpineBoots() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "lab-alpine", boot: .alpine())) { vm in
				let console = try await vm.console(0)
				defer { console.close() }
				let ready = try await console.expect("LAB-READY (\\S+)", timeout: .seconds(60))
				let alpine = try await LabFixtures.alpine()
				#expect(ready[1] == alpine.version)
				let answer = try await console.run("echo lab-$((40+2))")
				#expect(answer.status == 0)
				#expect(answer.output == "lab-42")
				// hvc0 is the shell's controlling terminal, so ^C reaches a foreground job
				// (/dev/tty opens only with one).
				let ctty = try await console.run("(: </dev/tty) 2>/dev/null && tty")
				#expect(ctty.status == 0 && ctty.output == "/dev/hvc0", "\(ctty)")
				let host = try await vm.hostPID()
				#expect(host > 0)
				let socket = try await vm.consoleSocketPath(0)
				#expect(FileManager.default.fileExists(atPath: socket))
			}
		}
	}

	@Test(
		"Q18: the Alpine fixture's HID log lists the USB keyboard and pointer when the lab opts in"
	)
	func alpineHIDLog() async throws {
		let options = LabAgent.Options(environment: ["MACHMAN_LAB_DEVICES": "hid"])
		try await Lab.withAgent(options) { agent in
			let spec = LabVMSpec(
				name: "lab-hid", boot: .alpine(), devices: [.keyboard, .pointer])
			try await agent.withVM(spec) { vm in
				let hid = try await vm.console(1)
				defer { hid.close() }
				let line = try await hid.expect("HID-(READY|NONE)([^\\n]*)", timeout: .seconds(60))
				#expect(line[1] == "READY")
				#expect(line[2].contains("event"))
			}
		}
	}
}

@Suite("Lab smoke L3", .serialized, .enabled(if: Lab.runs(.l3)))
struct LabSmokeL3Tests {
	// The fixture as the lab prepared it (scripts/lab/qemu/prepare.sh debian): the raw nocloud
	// image stops its first boot at systemd-firstboot's prompts on the system console and has
	// no root login until a password is set; the prepared one booted once, keeps root's
	// console login passwordless and runs a getty on hvc2 (hence three consoles).
	@Test("Q18: the Debian fixture boots to a login prompt on hvc0")
	func debianLogin() async throws {
		let image = try await LabGuest.debian.imagePath()
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(
				name: "lab-debian", boot: .efiImagePath(image), cpus: 2, memoryGiB: 2,
				consolePorts: 3)
			try await agent.withVM(spec, start: false) { vm in
				let console = try await vm.bootLoggedIn(0, label: "hvc0")
				defer { console.close() }
				let arch = try await console.run("uname -m")
				#expect(arch.status == 0)
				#expect(arch.output == "aarch64")
				let tty = try await console.run("tty")
				#expect(tty.output == "/dev/hvc0")
			}
		}
	}
}
