//
//  EngineDiscoveryTests.swift
//  MachmanLabTests
//
//  L2 — address discovery on the VZ NAT network, for VMs whose guest never reported a user:
//  no readiness probe runs, so nothing opens TCP to the guest (B-1); the agent only reads
//  /var/db/dhcpd_leases and arp. The Alpine fixture takes a lease with udhcpc. What the
//  desktop says about it (R4, F4) and the bridge address the agent serves (C25; the BSD
//  tab's text is a view, r3-3b).
//

import Darwin
import Foundation
import Testing
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

@Suite("Engine — address discovery", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineDiscoveryTests {
	static func spec(_ name: String) -> LabVMSpec {
		LabVMSpec(name: name, boot: .alpine(), network: true)
	}

	/// Boots the VM's lease and waits for the agent to serve its address.
	static func leased(_ agent: LabAgent, _ vm: LabVM) async throws -> (LabConsole, String) {
		let console = try await vm.console(0)
		try await console.expect("LAB-READY", timeout: .seconds(60))
		try await TFGuest.dhcp(console)
		let info = try await TFWait.vm(agent.api, vm.name, "addressed", timeout: .seconds(90)) {
			$0.ssh?.address != nil
		}
		return (console, info.ssh!.address!)
	}

	/// This Mac's IPv4 address on the interface whose subnet holds `guest` (the longest
	/// prefix), from getifaddrs — the rule the agent's discovery follows.
	static func macAddress(seenFrom guest: String) -> String? {
		func v4(_ text: String) -> UInt32? {
			var addr = in_addr()
			return inet_pton(AF_INET, text, &addr) == 1 ? UInt32(bigEndian: addr.s_addr) : nil
		}
		guard let target = v4(guest) else { return nil }
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0, let first = head else { return nil }
		defer { freeifaddrs(head) }
		var best: (address: UInt32, bits: Int)?
		for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let item = entry.pointee
			guard item.ifa_flags & UInt32(IFF_UP) != 0, let address = item.ifa_addr,
				address.pointee.sa_family == sa_family_t(AF_INET), let mask = item.ifa_netmask
			else { continue }
			let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
				UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
			}
			var m: UInt32 = 0
			withUnsafeMutableBytes(of: &m) { raw in
				let length = min(Int(mask.pointee.sa_len), MemoryLayout<sockaddr_in>.size)
				let offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!
				let bytes = UnsafeRawPointer(mask)
				for index in 0..<4 where offset + index < length {
					raw[index] = bytes.load(fromByteOffset: offset + index, as: UInt8.self)
				}
			}
			m = UInt32(bigEndian: m)
			guard m != 0, a != target, a & m == target & m else { continue }
			if best == nil || m.nonzeroBitCount > best!.bits { best = (a, m.nonzeroBitCount) }
		}
		guard let best else { return nil }
		let b = best.address
		return "\(b >> 24).\((b >> 16) & 0xFF).\((b >> 8) & 0xFF).\(b & 0xFF)"
	}

	@Test("R4: a networked VM that never used SSH raises no SSH toast")
	func noSSHToastWithoutSSH() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			try await agent.withVM(Self.spec("r4")) { vm in
				let (console, _) = try await Self.leased(agent, vm)
				defer { console.close() }
				try await Task.sleep(for: .seconds(30))
				#expect(!desktop.toasts.messages.contains { $0.contains("SSH") })
				let reach = try await vm.info().ssh?.reachability
				#expect(reach == nil || reach == .unknown)
			}
			await desktop.close()
		}
	}

	@Test("W3-45: re-running address discovery says the VM is still at its address")
	func rediscoverySaysStillAt() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			try await agent.withVM(Self.spec("f4")) { vm in
				let (console, address) = try await Self.leased(agent, vm)
				defer { console.close() }
				try await desktop.waitForEntry("f4", "addressed", timeout: .seconds(10)) {
					$0.ssh?.address != nil
				}
				desktop.viewModel.rediscoveryWait = .seconds(60)
				let before = desktop.toasts.entries.count
				desktop.viewModel.refreshSSH("f4")
				try await desktop.toasts.waitFor("Looking for f4’s address…", timeout: .seconds(5))
				let answers = ["f4 is still at \(address)", "f4 answered — \(address)"]
				try await TFWait.until("the rediscovery's answer", timeout: .seconds(30)) {
					desktop.toasts.entries.dropFirst(before).contains {
						answers.contains($0.message)
					}
				}
				try await Task.sleep(for: .seconds(2))
				let after = desktop.toasts.entries.dropFirst(before).map(\.message)
				#expect(after.filter { answers.contains($0) }.count == 1)
				#expect(!after.contains { $0.hasPrefix("No address for") })
				let looking = desktop.toasts.entries.first {
					$0.message == "Looking for f4’s address…"
				}
				#expect(looking?.spinner == true)
			}
			await desktop.close()
		}
	}

	@Test("R3W2-12: the Mac's bridge address is served while a NAT VM runs, and not after")
	func bridgeAddressServedWhileRunning() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(Self.spec("c25")) { vm in
				let (console, address) = try await Self.leased(agent, vm)
				let expected = try #require(Self.macAddress(seenFrom: address))
				let served = try await TFWait.vm(
					agent.api, "c25", "served the bridge", timeout: .seconds(20)
				) { $0.ssh?.hostAddressForGuest != nil }
				#expect(served.ssh?.hostAddressForGuest == expected)
				console.close()
				let host = try await vm.hostPID()
				try await vm.stop()
				#expect(await LabProcesses.waitForExit(host, timeout: .seconds(30)))
				// No run, no overlay: the entry carries neither address once its vmhost went.
				let stopped = try await TFWait.vm(
					agent.api, "c25", "without a live overlay", timeout: .seconds(10)
				) { $0.ssh?.address == nil }
				#expect(stopped.ssh?.hostAddressForGuest == nil)
			}
		}
	}
}
