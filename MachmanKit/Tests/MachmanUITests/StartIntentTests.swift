//
//  StartIntentTests.swift
//  MachmanUITests
//
//  Decision 7 as one rule (P21): a plain Start follows the VM's start policy, and a named
//  item overrides only what it names. The Dock, the picker, the Run menu, the toolbar and the
//  menu-bar agent all send what this returns.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanUI

struct StartIntentTests {
	private func vm(_ policy: StartPolicy?) -> VMInfo {
		VMInfo(
			name: "alpha", state: .stopped, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil),
			startPolicy: policy)
	}

	@Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
	func plainFollowsThePolicy(windowed: Bool, safe: Bool) {
		let options = vm(StartPolicy(windowed: windowed, safe: safe)).startOptions()
		#expect(options == StartOptions(openWindow: windowed, force: false, safe: safe))
	}

	@Test func aPrePolicyDaemonsVMStartsWindowedAndUnsafe() {
		#expect(vm(nil).startOptions(.plain) == StartOptions(openWindow: true, safe: false))
	}

	@Test func headlessKeepsThePolicysSafety() {
		let safe = vm(StartPolicy(windowed: true, safe: true))
		#expect(safe.startOptions(.headless) == StartOptions(openWindow: false, safe: true))
		let plain = vm(StartPolicy(windowed: true, safe: false))
		#expect(plain.startOptions(.headless) == StartOptions(openWindow: false, safe: false))
	}

	@Test func safeKeepsThePolicysWindowMode() {
		let headless = vm(StartPolicy(windowed: false, safe: false))
		#expect(headless.startOptions(.safe) == StartOptions(openWindow: false, safe: true))
		let windowed = vm(StartPolicy(windowed: true, safe: false))
		#expect(windowed.startOptions(.safe) == StartOptions(openWindow: true, safe: true))
	}

	// W10: vm.start takes explicit options only, so a client that skips the policy starts a
	// headless or safe VM windowed and unsafe. The documented non-Swift client applies it the
	// same way: its start options, read from the script itself, match this rule.
	@Test("W10: machman-smoke.py starts a VM the way StartIntent does")
	func theSmokeScriptFollowsTheStartPolicy() async throws {
		let policies: [StartPolicy?] = [
			nil, StartPolicy(), StartPolicy(windowed: false), StartPolicy(safe: true),
			StartPolicy(windowed: false, safe: true),
		]
		let intents: [(StartIntent, String)] = [(.plain, ""), (.headless, "--headless"),
			(.safe, "--safe")]
		var cases: [[String]] = []
		var expected: [StartOptions] = []
		for policy in policies {
			let json = try policy.map {
				String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
			}
			for (intent, flag) in intents {
				cases.append([json ?? "null", flag])
				expected.append(vm(policy).startOptions(intent))
			}
		}
		let code = """
			import importlib.util, json, sys
			spec = importlib.util.spec_from_file_location("smoke", sys.argv[1])
			smoke = importlib.util.module_from_spec(spec)
			spec.loader.exec_module(smoke)
			out = []
			for policy, flag in json.loads(sys.argv[2]):
			    vm = {"name": "alpha", "startPolicy": json.loads(policy)}
			    out.append(smoke.start_options(vm, [flag] if flag else []))
			sys.stdout.write(json.dumps(out))
			"""
		let input = String(decoding: try JSONEncoder().encode(cases), as: UTF8.self)
		let result = try await Subprocess.run(
			"/usr/bin/python3",
			["-I", "-B", "-c", code, RepoFiles.url("scripts/machman-smoke.py").path, input])
		#expect(result.status == 0, "\(result.output)")
		let got = try JSONDecoder().decode(
			[[String: Bool]].self, from: Data(result.output.utf8))
		#expect(got.count == expected.count)
		for (options, answer) in zip(expected, got) {
			#expect(answer == ["openWindow": options.openWindow, "safe": options.safe])
		}
	}
}
