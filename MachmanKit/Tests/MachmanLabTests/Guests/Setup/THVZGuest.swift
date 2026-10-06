//
//  THVZGuest.swift
//  MachmanLabTests
//
//  A prepared Linux image (Debian, Debian-sysv, Alpine) as a Machman VM of the lab agent with
//  Guest Setup on, NAT and three consoles; hvc2 is the driver (the prepared getty, root with
//  no password). After the first login: the guest's network rules (THNet: <gateway>:22 is the
//  lab sshd, nothing else leaves), a user `lab`, and the share mounted by the Linux guide's
//  line. Driven over the console only — no host→guest TCP (B-1).
//

import Foundation
import MachmanAPI
import MachmanDesktopCore

final class THVZGuest: THGuest, @unchecked Sendable {
	let kind: THGuestKind
	let agent: LabAgent
	let vm: THVM
	private(set) var mac: THMac?
	private(set) var driver: LabConsole
	let options: THGuestOptions
	private(set) var gateway = ""
	private var boots = 1
	private let ownsMac: Bool

	private init(
		kind: THGuestKind, agent: LabAgent, vm: THVM, mac: THMac?, driver: LabConsole,
		options: THGuestOptions, ownsMac: Bool
	) {
		self.kind = kind
		self.agent = agent
		self.vm = vm
		self.mac = mac
		self.driver = driver
		self.options = options
		self.ownsMac = ownsMac
	}

	/// The VM spec for `kind` (its image cloned into the scope).
	static func spec(_ kind: THGuestKind, _ options: THGuestOptions, agent: LabAgent)
		async throws -> LabVMSpec {
		let image = try await kind.imagePath()
		var devices: [DeviceKind] = [.guestSetup]
		if options.graphics { devices.append(.graphics) }
		if options.rosetta { devices.append(.rosetta) }
		var mounts: [LabVMSpec.Mount] = []
		for tag in options.mounts.keys.sorted() {
			mounts.append(.init(path: try TH.hostDir(agent, tag), tag: tag))
		}
		let small = kind == .alpine
		return LabVMSpec(
			name: options.name ?? "guest-\(kind.stem)", boot: .efiImagePath(image),
			cpus: small ? 1 : 2, memoryGiB: small ? 1 : 2, consolePorts: options.consoles,
			network: options.network, devices: devices, mounts: mounts)
	}

	static func boot(_ kind: THGuestKind, _ options: THGuestOptions, agent: LabAgent)
		async throws -> THVZGuest {
		let spec = try await spec(kind, options, agent: agent)
		let vm = try await THVM.create(spec, on: agent)
		var guest: THVZGuest?
		do {
			for (tag, mountKind) in options.mounts {
				guard let mountKind else { continue }
				let info = try await vm.info()
				guard let mount = info.mounts.first(where: { $0.tag == tag }) else { continue }
				_ = try await agent.api.setMountKind(
					vm: vm.name, mountID: mount.id, kind: mountKind)
			}
			let driver = try await vm.bootLoggedIn(2, label: "hvc2")
			guest = THVZGuest(
				kind: kind, agent: agent, vm: vm, mac: nil, driver: driver, options: options,
				ownsMac: true)
			try await guest!.firstLogin()
			return guest!
		} catch {
			if let guest { await guest.shutdown() } else { await vm.cleanup() }
			throw error
		}
	}

	/// A second guest in the same scope on an existing VM (a copy), sharing this guest's Mac.
	func sibling(_ other: THVM) async throws -> THVZGuest {
		let driver = try await other.bootLoggedIn(2, label: "hvc2")
		let guest = THVZGuest(
			kind: kind, agent: agent, vm: other, mac: mac, driver: driver, options: options,
			ownsMac: false)
		guest.gateway = gateway
		try await guest.afterBoot()
		return guest
	}

	// Network rules, the lab user, the share.
	private func firstLogin() async throws {
		if options.network {
			gateway = try await defaultGateway()
			mac = try await THMac.start(bind: .vmnet, scope: agent.scope)
			for line in THNet.install(kind, gateway: gateway, port: mac?.port ?? 1) {
				try await root(line)
			}
			try await root(THNet.loadedCheck)
		}
		if kind == .debian {
			// Nothing scheduled may run during a row (the network is closed anyway).
			_ = try? await root(
				"systemctl stop apt-daily.timer apt-daily-upgrade.timer systemd-timesyncd"
					+ " >/dev/null 2>&1; true")
		}
		try await makeLabUser()
		try await mountShare()
	}

	// After a boot: rules loaded again (persisted), the share mounted again (`remount`).
	private func afterBoot(remount: Bool = true) async throws {
		if options.network {
			let loaded = try await THConsoleSession.run(
				driver, THNet.loadedCheck, timeout: .seconds(30))
			if loaded.status != 0 {
				throw LabError.commandFailed(
					command: "the guest's lab network rules after a boot", status: loaded.status,
					output: loaded.output)
			}
		}
		if remount { try await mountShare() }
	}

	private func makeLabUser() async throws {
		let add = kind == .alpine
			? "adduser -D -s /bin/sh lab && sed -i 's/^lab:!:/lab:*:/' /etc/shadow"
			: "useradd -m -s /bin/sh lab"
		try await root("id lab >/dev/null 2>&1 || { \(add); }")
		let doas = kind == .alpine ? "/etc/doas.d/th-lab.conf" : "/etc/doas.conf"
		switch options.labUser {
		case .nopasswd:
			try await root(
				"mkdir -p /etc/sudoers.d && echo 'lab ALL=(ALL) NOPASSWD: ALL'"
					+ " > /etc/sudoers.d/th-lab && chmod 440 /etc/sudoers.d/th-lab")
			try await root(
				"mkdir -p \((doas as NSString).deletingLastPathComponent) && echo"
					+ " 'permit nopass lab' > \(doas) && chmod 600 \(doas)")
		case .password:
			let group = kind == .alpine ? "wheel" : "sudo"
			try await root("echo lab:lab | chpasswd && \(addToGroup("lab", group))")
			if kind == .alpine {
				try await root(
					"mkdir -p /etc/sudoers.d && echo '%wheel ALL=(ALL) ALL'"
						+ " > /etc/sudoers.d/th-wheel && chmod 440 /etc/sudoers.d/th-wheel")
			}
			try await root(
				"mkdir -p \((doas as NSString).deletingLastPathComponent) && echo"
					+ " 'permit persist lab' > \(doas) && chmod 600 \(doas)")
		}
	}

	private func addToGroup(_ user: String, _ group: String) -> String {
		kind == .alpine ? "addgroup \(user) \(group)" : "usermod -aG \(group) \(user)"
	}

	/// The Linux guide's mount line, as root, unless the share is mounted already.
	func mountShare() async throws {
		guard options.mountShare else { return }
		try await root(
			"mountpoint -q \(GuestPaths.share) || { \(GuestSetupCommands.mountShareLine.text); }")
	}

	/// The default gateway once DHCP gave the guest one.
	private func defaultGateway() async throws -> String {
		let deadline = ContinuousClock.now + .seconds(90)
		while true {
			let route = try await THConsoleSession.run(
				driver, "ip -4 route show default | awk '{ print $3; exit }'",
				timeout: .seconds(30))
			let address = route.output.trimmingCharacters(in: .whitespacesAndNewlines)
			if route.status == 0, address.split(separator: ".").compactMap({ UInt8($0) })
				.count == 4 {
				return address
			}
			if ContinuousClock.now >= deadline {
				throw LabError.stateTimeout(vm: vm.name, wanted: "a default route", last: "none")
			}
			try await Task.sleep(for: .seconds(2))
		}
	}

	/// One root command on the driver (it may use the console); a non-zero exit throws.
	@discardableResult
	func root(_ command: String, timeout: Duration = .seconds(120)) async throws -> String {
		let result = try await THConsoleSession.run(driver, command, timeout: timeout)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: command, status: result.status, output: result.output)
		}
		return result.output
	}

	func exec(_ command: String, user: String?, timeout: Duration) async throws
		-> (status: Int32, output: String) {
		let inner = user.map { "su -l \($0) -c \(ShellQuote.single(command))" } ?? command
		return try await THConsoleSession.run(
			driver, "setsid -w sh -c \(ShellQuote.single(inner)) </dev/null 2>&1",
			timeout: timeout)
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
		TH.log("\(vm.name): the driver did not come back; booting again")
		try? await restartFromHost()
	}

	func reboot(remount: Bool) async throws {
		try driver.send(kind == .debian ? "systemctl reboot" : "reboot")
		boots += 1
		// VZ restarts the guest in place (the driver's connection sees the new boot's getty);
		// should the VM stop instead, it is started again.
		let deadline = ContinuousClock.now + .seconds(240)
		var inPlace = false
		while ContinuousClock.now < deadline {
			if try await vm.info().state == .stopped { break }
			if (try? await driver.expect("login: *$", timeout: .seconds(5))) != nil {
				inPlace = true
				break
			}
		}
		if inPlace, (try? await driver.login(user: "root", timeout: .seconds(60))) != nil {
			try await afterBoot(remount: remount)
			return
		}
		driver.close()
		if try await vm.info().state.isRunning {
			TH.log("\(vm.name): no login after the reboot; booting again")
			try await vm.stop(.force)
		} else {
			try await vm.guestStopped()
		}
		driver = try await vm.bootLoggedIn(2, label: "hvc2-boot\(boots)")
		try await afterBoot(remount: remount)
	}

	/// The guest powers itself off (the VM stops, its vmhost exits).
	func powerOff() async throws {
		try driver.send(kind == .debian ? "systemctl poweroff" : "poweroff")
		try await vm.guestStopped(timeout: .seconds(180))
		driver.close()
	}

	/// A new connection to the driver console with root logged in (after something ended
	/// the old session).
	func reconnectDriver() async throws {
		driver.close()
		boots += 1
		driver = try await vm.loggedInConsole(2, label: "hvc2-again\(boots)")
	}

	/// The VM stopped from the host (force: `sync` first) and started again — a new run of
	/// its vmhost, which serves the payload by the rules of a start.
	func restartFromHost(remount: Bool = true) async throws {
		_ = try? await THConsoleSession.run(driver, "sync", timeout: .seconds(60))
		driver.close()
		try await vm.restart(.force)
		boots += 1
		driver = try await vm.bootLoggedIn(2, label: "hvc2-boot\(boots)")
		try await afterBoot(remount: remount)
	}

	func shutdown() async {
		driver.close()
		await vm.cleanup()
		if ownsMac { await mac?.stop() }
	}
}
