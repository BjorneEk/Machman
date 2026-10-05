//
//  EngineReadinessTests.swift
//  MachmanLabTests
//
//  The SSH readiness probe (the agent's TCP connect to a guest's port 22) and what the
//  desktop says about it. That connect reaches the VM network (192.168.64.x) from the lab
//  agent and can raise macOS's Local Network prompt, so both suites are opt-in (B-1):
//  without MACHMAN_LAB_LOCAL_NETWORK=1 they skip with "Deferred: local network (opt-in
//  MACHMAN_LAB_LOCAL_NETWORK=1)". The agent's own guard (SSHDiscovery.probeAllowed) reads
//  the same variable, so an opted-out run never probes. This wave never sets it.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

// L3 — the Debian guest (prepared image, VZ) as the subject: its real sshd answers or not.
@Suite(
	"Engine — ssh readiness L3", .serialized,
	.enabled(if: Lab.runs(.l3) && TFGate.localNetwork, TFGate.localNetworkReason))
@MainActor
struct EngineReadinessL3Tests {
	/// A Debian VM whose report says root set it up, booted fresh so the probe starts.
	static func reportedDebian(
		_ agent: LabAgent, _ name: String, prepare: String? = nil
	) async throws -> (LabVM, LabConsole) {
		let image = try await LabGuest.debian.imagePath()
		let spec = LabVMSpec(
			name: name, boot: .efiImagePath(image), cpus: 2, memoryGiB: 2, consolePorts: 3,
			network: true, devices: [.guestSetup])
		let vm = try await LabVM.create(spec, on: agent)
		var console = try await vm.bootLoggedIn(2, label: "hvc2")
		_ = try await console.run(
			"mkdir -p /mnt/s && (mountpoint -q /mnt/s || mount -t virtiofs host-share /mnt/s)")
		let key = try await console.run("cat /etc/ssh/ssh_host_ed25519_key.pub")
		try await TFGuest.writeReport(
			console, TFReport.standard(hostKey: key.output).render())
		if let prepare { _ = try await console.run(prepare, timeout: .seconds(60)) }
		console.close()
		try await TFWait.vm(agent.api, name, "reported", timeout: .seconds(20)) {
			$0.ssh?.guestUser == "root"
		}
		try await vm.stop()
		console = try await vm.bootLoggedIn(2, label: "hvc2-again")
		return (vm, console)
	}

	@Test("R1: a configured Debian guest goes from SSH connecting to SSH ready")
	func connectingThenReady() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			let (vm, console) = try await Self.reportedDebian(agent, "r1")
			defer { console.close() }
			try await desktop.toasts.waitFor("r1: SSH connecting…", timeout: .seconds(120))
			try await desktop.toasts.waitFor("r1: SSH ready", timeout: .seconds(120))
			#expect(try await vm.info().ssh?.reachability == .ready)
			let connecting = desktop.toasts.entries.firstIndex {
				$0.message == "r1: SSH connecting…"
			}
			let ready = desktop.toasts.entries.firstIndex { $0.message == "r1: SSH ready" }
			#expect(connecting != nil && ready != nil && connecting! < ready!)
			await desktop.close()
		}
	}

	@Test(
		"""
		R2: with sshd stopped the guest reads not answering, and a retry finds it once sshd \
		is back
		""")
	func notAnsweringThenRetry() async throws {
		let options = LabAgent.Options(environment: ["MACHMAN_LAB_SSH_READY_SECONDS": "20"])
		try await Lab.withAgent(options) { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			let (vm, console) = try await Self.reportedDebian(
				agent, "r2", prepare: "systemctl disable --now ssh.service ssh.socket")
			defer { console.close() }
			let index = try await desktop.toasts.waitFor(
				"r2: SSH not answering", timeout: .seconds(90))
			#expect(desktop.toasts.entries[index].message.hasSuffix(":22 after 3 minutes"))
			#expect(try await vm.info().ssh?.reachability == .unreachable)
			_ = try await console.run("systemctl start ssh")
			desktop.viewModel.refreshSSH("r2")
			try await desktop.toasts.waitFor("r2: SSH ready", timeout: .seconds(60))
			await desktop.close()
		}
	}
}

// L2 — the Alpine fixture with an nc listener on port 22 standing in for sshd.
@Suite(
	"Engine — ssh readiness", .serialized,
	.enabled(if: Lab.runs(.l2) && TFGate.localNetwork, TFGate.localNetworkReason))
@MainActor
struct EngineReadinessTests {
	static func spec(_ name: String) -> LabVMSpec {
		LabVMSpec(name: name, boot: .alpine(), network: true, devices: [.guestSetup])
	}

	@Test("W3-45: Check Connection on an SSH guest says it answered at its address")
	func checkConnectionAnswers() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			try await agent.withVM(Self.spec("f4-ssh")) { vm in
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				try await TFGuest.mountShare(console)
				try await TFGuest.writeReport(console, TFReport.standard().render())
				try await TFGuest.dhcp(console)
				try await TFGuest.listen22(console)
				try await TFWait.vm(agent.api, vm.name, "ready", timeout: .seconds(120)) {
					$0.ssh?.reachability == .ready
				}
				let address = try #require(try await vm.info().ssh?.address)
				desktop.viewModel.rediscoveryWait = .seconds(60)
				let before = desktop.toasts.entries.count
				desktop.viewModel.refreshSSH(vm.name)
				try await desktop.toasts.waitFor(
					"Looking for f4-ssh’s address…", timeout: .seconds(5))
				let answers = ["f4-ssh is still at \(address)", "f4-ssh answered — \(address)"]
				try await TFWait.until("the answer and SSH ready", timeout: .seconds(60)) {
					let after = desktop.toasts.entries.dropFirst(before).map(\.message)
					return after.contains { answers.contains($0) }
						&& after.contains("f4-ssh: SSH ready")
				}
			}
			await desktop.close()
		}
	}

	@Test("R3W2-15: a VM saved from a safe run goes to SSH ready from events alone")
	func savedSafeRunGoesReady() async throws {
		try await Lab.withAgent { agent in
			let events = await TFEvents(api: agent.api)
			defer { events.stop() }
			try await agent.withVM(Self.spec("e42")) { vm in
				let first = try await vm.console(0)
				try await first.expect("LAB-READY", timeout: .seconds(60))
				try await TFGuest.mountShare(first)
				try await TFGuest.writeReport(first, TFReport.standard().render())
				try await TFWait.vm(agent.api, vm.name, "reported", timeout: .seconds(20)) {
					$0.ssh?.guestUser == "root"
				}
				first.close()
				try await vm.stop()
				let desktop = try await TFDesktop.make(agent: agent)
				try await TFVM.start(
					agent, vm.name, options: StartOptions(openWindow: false, safe: true))
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				try await TFGuest.dhcp(console)
				try await TFWait.vm(agent.api, vm.name, "waiting", timeout: .seconds(90)) {
					$0.ssh?.reachability == .waiting
				}
				_ = try await agent.api.safeSave(vm: vm.name, to: "e42-kept")
				try await TFGuest.listen22(console)
				try await events.waitFor("sshChanged for e42-kept", timeout: .seconds(60)) {
					$0 == .sshChanged(vm: "e42-kept")
				}
				try await desktop.waitForEntry("e42-kept", "ready", timeout: .seconds(60)) {
					$0.ssh?.reachability == .ready
				}
				await TFVM.forceStop(agent, "e42-kept")
				await desktop.close()
			}
		}
	}
}
