//
//  VZFreeBSDTests.swift
//  MachmanLabTests
//
//  L3 — the vzfreebsd image under VZ, when its tree has built one (skipped with
//  import.sh's sentence otherwise): EFI boot, a root login on its virtio console (ttyV0.0),
//  vtnet0 on the NAT network, a clean power-off. Console only (T12).
//

import Foundation
import Testing

@Suite("L3 vzfreebsd", .serialized, .enabled(if: Lab.runs(.l3)))
struct VZFreeBSDTests {
	@Test(
		"Q18: the vzfreebsd image boots under VZ and logs in on ttyV0.0",
		.enabled(if: VZFreeBSD.sourceImageExists, Comment(rawValue: VZFreeBSD.skipReason)))
	func vzfreebsdBoots() async throws {
		let image = try await VZFreeBSD.importedPath()
		LabScripts.log("vzfreebsd import record:\n\(await VZFreeBSD.record())")
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(
				name: "lab-vzfreebsd", boot: .efiImagePath(image), cpus: 2, memoryGiB: 2,
				consolePorts: 1, network: true)
			try await agent.withVM(spec) { vm in
				let console = try await vm.loggedInConsole(0, label: "ttyV0.0")
				defer { console.close() }
				let kernel = try await console.run("uname -i")
				#expect(kernel.output == "VZ")
				// DHCP runs in the background: vtnet0 has an address within a minute.
				let deadline = ContinuousClock.now + .seconds(60)
				var inet = try await console.run("ifconfig vtnet0 | grep -q 'inet '")
				while inet.status != 0, ContinuousClock.now < deadline {
					try await Task.sleep(for: .seconds(2))
					inet = try await console.run("ifconfig vtnet0 | grep -q 'inet '")
				}
				#expect(inet.status == 0)
				try console.send("shutdown -p now")
				try await vm.guestStopped(timeout: .seconds(120))
			}
		}
	}
}
