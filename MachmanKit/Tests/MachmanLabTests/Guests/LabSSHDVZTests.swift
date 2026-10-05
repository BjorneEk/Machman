//
//  LabSSHDVZTests.swift
//  MachmanLabTests
//
//  L3 — the lab sshd as "the Mac" for a VZ guest. A guest finds the Mac as its default
//  gateway on port 22 (the Guest Setup's `ssh mac`, its sshfs mounts); on VZ NAT that is this
//  Mac's real sshd, so the lab sshd listens on the NAT bridge's address at a port of its own
//  and an nft DNAT inside the guest (guest.sh lab-redirect) sends <gateway>:22 there — before
//  any guest→Mac flow. Driven over the hvc2 console only (T12).
//

import Foundation
import Testing

@Suite("L3 lab sshd under VZ", .serialized, .enabled(if: Lab.runs(.l3)))
struct LabSSHDVZTests {
	@Test(
		"Q18: a VZ guest reaches the lab sshd as the Mac on port 22",
		.enabled(
			Comment(
				rawValue: "the Application Firewall would prompt for a listener on the VZ"
					+ " bridge (scripts/lab/sshd/sshd.sh doctor)")
		) { await LabSSHD.doctor().bridgeOK })
	func vzGuestReachesLabSSHD() async throws {
		let image = try await LabGuest.debian.imagePath()
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(
				name: "lab-sshd-vz", boot: .efiImagePath(image), cpus: 2, memoryGiB: 2,
				consolePorts: 3, network: true)
			try await agent.withVM(spec, start: false) { vm in
				let console = try await vm.bootLoggedIn(2, label: "hvc2")
				defer { console.close() }
				let gateway = try await defaultGateway(console)
				// The bridge exists now (the VM is on NAT): the lab sshd listens on it.
				try await LabSSHD.with(bind: .vmnet) { sshd in
					#expect(sshd.host == gateway)
					let redirect = try await LabScripts.check(
						LabScripts.guest(os: "debian"),
						["lab-redirect", gateway, String(sshd.port)])
					for line in redirect.split(separator: "\n") {
						try await shell(console, String(line))
					}
					let pub = try await shell(
						console,
						"mkdir -p -m 700 /root/.ssh && rm -f /root/.ssh/lab_mac*"
							+ " && ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/lab_mac"
							+ " && cat /root/.ssh/lab_mac.pub")
					try await sshd.authorize(publicKey: pub)
					let ssh = "ssh -F /dev/null -i /root/.ssh/lab_mac -o BatchMode=yes"
						+ " -o UserKnownHostsFile=/root/lab_known -o ConnectTimeout=10"
						+ " -o LogLevel=ERROR \(LabSSHD.macUser)@\(gateway)"
					// First contact learns the host key, as a fresh guest would.
					let first = try await shell(
						console, "rm -f /root/lab_known; \(ssh) -o StrictHostKeyChecking=accept-new"
							+ " 'echo $HOME'")
					#expect(first == sshd.home)
					// The pinned path the Guest Setup uses: the lab host key under the
					// gateway's name, StrictHostKeyChecking=yes.
					let pinned = try sshd.knownHostsLine(for: gateway)
					try await shell(
						console, "ssh-keygen -R \(gateway) -f /root/lab_known >/dev/null 2>&1;"
							+ " echo '\(pinned)' > /root/lab_known")
					let again = try await shell(
						console, "\(ssh) -o StrictHostKeyChecking=yes 'echo $HOME'")
					#expect(again == sshd.home)
				}
			}
		}
	}

	/// The guest's default gateway (the NAT bridge's address) once DHCP gave it one.
	private func defaultGateway(_ console: LabConsole) async throws -> String {
		let deadline = ContinuousClock.now + .seconds(60)
		while true {
			let route = try await console.run("ip -4 route show default | awk '{ print $3; exit }'")
			if route.status == 0, !route.output.isEmpty { return route.output }
			if ContinuousClock.now >= deadline {
				throw LabError.stateTimeout(
					vm: "lab-sshd-vz", wanted: "a default route", last: "none")
			}
			try await Task.sleep(for: .seconds(2))
		}
	}

	@discardableResult
	private func shell(_ console: LabConsole, _ command: String) async throws -> String {
		let result = try await console.run(command, timeout: .seconds(60))
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: command, status: result.status, output: result.output)
		}
		return result.output
	}
}
