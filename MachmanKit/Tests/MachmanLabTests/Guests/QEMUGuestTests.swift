//
//  QEMUGuestTests.swift
//  MachmanLabTests
//
//  L3 — lab guests under QEMU: the prepared FreeBSD and Debian images under the headless
//  runner, the lab sshd as "the Mac" behind the lab gateway, and the guest-regress suites
//  inside real guests (scripts/lab.sh --guests runs them).
//

import Foundation
import Testing

@Suite("L3 QEMU guests", .serialized, .enabled(if: Lab.runs(.l3)))
struct QEMUGuestTests {
	@Test(
		"Q18: FreeBSD boots under QEMU and logs in on the serial console",
		arguments: [LabGuest.freebsd14, .freebsd15])
	func freebsdBoots(guest: LabGuest) async throws {
		try await QEMUGuest.with(guest, name: "q-\(guest)", consoles: 0) { vm in
			let console = try await vm.console()
			defer { console.close() }
			try await console.login(user: "root", timeout: .seconds(120))
			let version = try await console.run("freebsd-version -u")
			#expect(version.status == 0)
			#expect(version.output.hasPrefix((guest.release ?? "?") + "-"))
			let lines = try await vm.sshCheck(
				"uname -r; doas id -u; pkg info -e fusefs-sshfs && echo sshfs")
				.split(separator: "\n").map(String.init)
			#expect(lines.count == 3)
			#expect(lines.first?.hasPrefix((guest.release ?? "?") + "-") == true)
			#expect(lines.dropFirst().first == "0")
			#expect(lines.last == "sshfs")
		}
	}

	@Test("Q18: a QEMU guest reaches the lab sshd as the Mac on port 22")
	func guestReachesLabSSHD() async throws {
		try await LabSSHD.with { sshd in
			try await QEMUGuest.with(.freebsd15, name: "q-sshd", labSSHD: sshd, consoles: 0) {
				vm in
				let pub = try await vm.sshCheck(
					"rm -f .ssh/lab_mac .ssh/lab_mac.pub && "
						+ "ssh-keygen -q -t ed25519 -N '' -f .ssh/lab_mac && cat .ssh/lab_mac.pub")
				try await sshd.authorize(publicKey: pub)
				let gateway = QEMUGuest.gateway
				let pinned = try sshd.knownHostsLine(for: gateway)
				try await vm.sshCheck("echo '\(pinned)' > .ssh/lab_known")
				// Port 22 of the guest's default gateway, the host key pinned: what the Guest
				// Setup's `ssh mac` and sshfs mounts do (StrictHostKeyChecking=yes).
				let ssh = "ssh -F /dev/null -i .ssh/lab_mac -o BatchMode=yes"
					+ " -o UserKnownHostsFile=.ssh/lab_known -o StrictHostKeyChecking=yes"
					+ " -o ConnectTimeout=10 \(LabSSHD.macUser)@\(gateway)"
				let home = try await vm.sshCheck("\(ssh) 'echo $HOME'")
				#expect(home == sshd.home)
				let route = try await vm.sshCheck("netstat -rn -f inet | awk '$1 == \"default\"'")
				#expect(route.contains(gateway))
				// A different pinned key is refused: the pin is what lets the guest in.
				try await vm.sshCheck(
					"ssh-keygen -q -t ed25519 -N '' -f .ssh/other_host </dev/null"
						+ " && printf '%s ' \(gateway) > .ssh/lab_known"
						+ " && cut -d' ' -f1-2 .ssh/other_host.pub >> .ssh/lab_known")
				let refused = try await vm.ssh("\(ssh) true 2>&1")
				#expect(refused.status != 0)
				#expect(refused.output.contains("Host key verification failed"))
			}
		}
	}

	@Test("Q18: lab sshd sessions write only inside the run sandbox")
	func sshdSessionsStayInside() async throws {
		let result = try await LabScripts.run(LabScripts.sshd, ["--self-check"], timeout: 300)
		LabScripts.log("sshd.sh --self-check:\n\(result.output)")
		#expect(result.status == 0, "\(result.output)")
		#expect(result.output.contains("a session writes inside the sandbox only"))
		#expect(result.output.contains("sshd.sh --self-check: all ok"))
	}

	@Test(
		"R3W2-23: the guest-regress suites pass under QEMU",
		arguments: ["debian", "debian-sysv", "freebsd14", "freebsd15"])
	func guestRegressUnderQEMU(distro: String) async throws {
		let checks = try await GuestRegress.run(.qemu, distro: distro)
		let suites = try await GuestRegress.suites(for: distro)
		#expect(Set(checks.map(\.suite)) == Set(suites))
		for check in checks {
			#expect(check.passed, "\(check)")
		}
	}
}
