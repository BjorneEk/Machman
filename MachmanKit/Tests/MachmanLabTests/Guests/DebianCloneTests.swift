//
//  DebianCloneTests.swift
//  MachmanLabTests
//
//  L3 — the lab's prepared Debian image as every Debian test boots it: one clone per VM. Each
//  clone has to be its own DHCP client (Q24): systemd-networkd derives its DHCP client id from
//  /etc/machine-id and bootpd keeps the lease under that id, so clones of an image with a
//  baked-in machine-id leased one address between them — parallel shards fought over it, and
//  whether a test found its guest depended on what ran before it.
//

import Foundation
import Testing

@Suite("L3 Debian clones", .serialized, .enabled(if: Lab.runs(.l3)))
struct DebianCloneTests {
	@Test("Q24: two Debian clones booted together lease different addresses")
	func clonesLeaseTheirOwnAddresses() async throws {
		try await Lab.withAgent { agent in
			let image = try await LabGuest.debian.imagePath()
			var consoles: [LabConsole] = []
			defer { consoles.forEach { $0.close() } }
			for name in ["clone-a", "clone-b"] {
				let vm = try await LabVM.create(
					LabVMSpec(
						name: name, boot: .efiImagePath(image), cpus: 2, memoryGiB: 2,
						consolePorts: 3, network: true),
					on: agent)
				consoles.append(try await vm.bootLoggedIn(2, label: "hvc2"))
			}
			var ids: [String] = []
			var addresses: [String] = []
			for console in consoles {
				ids.append(try await console.run("cat /etc/machine-id").output)
				addresses.append(try await TFGuest.address(console))
			}
			#expect(ids[0] != ids[1], "both clones run machine-id \(ids[0])")
			#expect(addresses[0] != addresses[1], "both clones leased \(addresses[0])")
		}
	}
}
