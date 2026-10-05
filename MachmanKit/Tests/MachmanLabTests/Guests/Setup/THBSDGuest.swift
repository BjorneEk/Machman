//
//  THBSDGuest.swift
//  MachmanLabTests
//
//  A FreeBSD guest for the Guest Setup rows: r3-td's prepared image under QEMU beside a running
//  "carrier" Machman VM of the lab agent. A QEMU guest has no Machman VM of its own, so it takes
//  the carrier's: the carrier (the Alpine netboot fixture, Guest Setup on, three consoles,
//  1 vCPU, no network) serves the payload in its share and ingests the report, and the
//  FreeBSD guest mounts that share over sshfs from "the Mac" — the lab sshd on 127.0.0.1, its
//  lab gateway 10.0.2.100:22 — by the BSD guide's own lines, as root. The carrier's VMInfo
//  carries the FreeBSD guest's report.
//
//  Bootstrap (T28): the lab sshd never takes a password, so the guide's unapproved mount
//  authenticates with root's and lab's keys, authorized for the run only; known_hosts get the
//  lab sshd's key under 10.0.2.100 (what a person accepts on first contact). The default route
//  is persisted (defaultrouter), so boot-time mounts find the Mac.
//

import Foundation
import MachmanAPI
import MachmanDesktopCore

final class THBSDGuest: THGuest, @unchecked Sendable {
	let kind: THGuestKind
	let agent: LabAgent
	let vm: THVM
	let mac: THMac?
	let qemu: QEMUGuest
	private(set) var driver: LabConsole
	private var boots = 1

	private init(
		kind: THGuestKind, agent: LabAgent, vm: THVM, mac: THMac, qemu: QEMUGuest,
		driver: LabConsole
	) {
		self.kind = kind
		self.agent = agent
		self.vm = vm
		self.mac = mac
		self.qemu = qemu
		self.driver = driver
	}

	/// The carrier's share as the BSD guide mounts it: the library's rename-stable link.
	var sharePath: String {
		get async throws {
			let info = try await vm.info()
			if let path = info.ssh?.setupSharePath { return path }
			return MachmanPaths.vmsDir(dataDir: agent.scope.dataDir) + "/.machman-shares/"
				+ (try THGuestFiles.marker(vm))
		}
	}

	var hostUser: String {
		get async throws { try await vm.info().ssh?.hostUser ?? NSUserName() }
	}

	static func boot(_ kind: THGuestKind, _ options: THGuestOptions, agent: LabAgent)
		async throws -> THBSDGuest {
		guard let labGuest = kind.labGuest, kind == .freebsd14 || kind == .freebsd15 else {
			throw LabError.specInvalid("\(kind) is not a QEMU FreeBSD guest")
		}
		guard let mac = try await THMac.start(bind: .loopback, scope: agent.scope) else {
			throw LabError.specInvalid("no lab sshd on loopback")
		}
		var carrier: THVM?
		var booted: QEMUGuest?
		do {
			let spec = LabVMSpec(
				name: options.name ?? "bsd carrier", boot: .alpine(), cpus: 1, memoryGiB: 1,
				consolePorts: options.bsdConsoles, devices: [.guestSetup])
			let vm = try await THVM.create(spec, on: agent)
			carrier = vm
			try await vm.start()
			let qemu = try await QEMUGuest.boot(
				labGuest, name: "th-\(kind.stem)", labSSHD: mac.sshd,
				consoles: options.bsdConsoles)
			booted = qemu
			let driver = try await qemu.console()
			try await driver.login(user: "root", timeout: .seconds(180))
			let guest = THBSDGuest(
				kind: kind, agent: agent, vm: vm, mac: mac, qemu: qemu, driver: driver)
			try await guest.bootstrap()
			if options.mountShare { try await guest.mountShare() }
			return guest
		} catch {
			await booted?.stop()
			await carrier?.cleanup()
			await mac.stop()
			throw error
		}
	}

	// Keys for root and lab that the lab sshd lets in for this run, the lab sshd's host key
	// accepted, the default route persisted.
	private func bootstrap() async throws {
		guard let mac else { return }
		let known = try mac.hostKeyLine(for: QEMUGuest.gateway)
		for (user, home) in [("root", "/root"), ("lab", "/home/lab")] {
			let key = "\(home)/.ssh/id_ed25519"
			let pub = try await check(
				"mkdir -p -m 700 \(home)/.ssh && { test -f \(key) || ssh-keygen -q -t ed25519"
					+ " -N '' -f \(key) </dev/null; } && echo \(ShellQuote.single(known))"
					+ " >> \(home)/.ssh/known_hosts && chown -R \(user) \(home)/.ssh"
					+ " && cat \(key).pub")
			try await mac.authorize(pub.split(separator: "\n").last.map(String.init) ?? pub)
		}
		try await check("sysrc defaultrouter=\(QEMUGuest.gateway) >/dev/null")
	}

	/// Steps 4 and 5 of the BSD guide as root: fusefs, then the share over sshfs.
	func mountShare() async throws {
		let mount = GuestSetupCommands.bsdShareMount(
			approvedGuestUser: nil, hostUser: try await hostUser,
			hostAddress: QEMUGuest.gateway, sharePath: try await sharePath)
		try await check(GuestEscalation.root.apply(GuestSetupCommands.bsdFuseLoad))
		try await check(
			"mount | grep -q ' on \(GuestPaths.share) ' || { \(GuestEscalation.root.apply(mount)); }",
			timeout: .seconds(60))
	}

	/// Drops the bootstrap keys (before rows that must reach the Mac on Machman's grant only).
	func dropBootstrapKeys() { mac?.deauthorize() }

	func exec(_ command: String, user: String?, timeout: Duration) async throws
		-> (status: Int32, output: String) {
		// ssh as lab (the image's baked key, the 127.0.0.1 forward: loopback only), no tty.
		let line = user == nil ? "doas sh -c \(ShellQuote.single(command))"
			: user == "lab" ? "sh -c \(ShellQuote.single(command))"
			: "doas su -l \(user!) -c \(ShellQuote.single(command))"
		let seconds = TimeInterval(timeout.components.seconds)
		let result = try await qemu.ssh(line + " </dev/null 2>&1", timeout: seconds)
		return (result.status, result.output.trimmingCharacters(in: .newlines))
	}

	func asUserShell<T>(_ user: String, _ body: () async throws -> T) async throws -> T {
		try driver.send("su -l \(user)")
		try await driver.expect("[$] *$", timeout: .seconds(30))
		do {
			let result = try await body()
			try driver.send("exit")
			try await driver.expect("[#] *$", timeout: .seconds(30))
			return result
		} catch {
			await recoverDriver()
			throw error
		}
	}

	func recoverDriver() async {
		for _ in 0..<4 {
			try? driver.sendRaw([0x03])
			try? await Task.sleep(for: .milliseconds(500))
			try? driver.send("")
			guard let id = try? await THConsoleSession.run(driver, "id -u", timeout: .seconds(10))
			else {
				continue
			}
			let last = id.output.split(separator: "\n").last.map(String.init)
			if id.status == 0 && last == "0" { return }
			try? driver.send("exit")
			try? await Task.sleep(for: .seconds(1))
		}
		TH.log("\(qemu.name): the serial console did not come back")
	}

	func reboot(remount: Bool) async throws {
		try await qemu.reboot()
		boots += 1
		try await driver.login(user: "root", timeout: .seconds(180))
		if remount {
			let mounted = try await sh("mount | grep -q ' on \(GuestPaths.share) '")
			if mounted.status != 0 { try await mountShare() }
		}
	}

	func shutdown() async {
		driver.close()
		await qemu.stop()
		await vm.cleanup()
		await mac?.stop()
	}
}
