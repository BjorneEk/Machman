//
//  THSpikeGuest.swift
//  MachmanLabTests
//
//  OpenBSD 7.9 and NetBSD 11.0 for the Guest Setup rows, on r3-td's spike images (T24; never
//  promoted to prepared lab guests, T14): a clone per test under the QEMU runner, root on the
//  serial console, the lab gateway 10.0.2.100 as "the Mac" (the lab sshd on loopback), and a
//  carrier VM's payload on a read-only disk image copied to /mnt/machman/share — the BSDs
//  have no virtiofs, and nothing on them can mount the share before the installer runs. The
//  report stays in the guest's copy (no ingestion: these rows read the guest).
//

import Foundation
import MachmanAPI
import MachmanTestSupport
import Testing

final class THSpikeGuest: THGuest, @unchecked Sendable {
	let kind: THGuestKind
	let agent: LabAgent
	let vm: THVM
	let mac: THMac?
	let name: String
	private(set) var driver: LabConsole

	private init(
		kind: THGuestKind, agent: LabAgent, vm: THVM, mac: THMac, name: String,
		driver: LabConsole
	) {
		self.kind = kind
		self.agent = agent
		self.vm = vm
		self.mac = mac
		self.name = name
		self.driver = driver
	}

	/// The spike image in the lab cache and how to make it when missing.
	static func image(_ kind: THGuestKind) -> (path: String, recipe: String) {
		let os = kind == .openbsd ? "openbsd" : "netbsd"
		let file = kind == .openbsd ? "openbsd-7.9.raw" : "netbsd-11.0-arm64.raw"
		return (Lab.cacheDir + "/spike/" + file,
			"\(os) spike image not built (scripts/lab/guests/bsd-spike/\(os).sh)")
	}

	static var rootPassword: [THGuestKind: String] { [.openbsd: "lab"] }

	var dir: String { Lab.runDir + "/qemu/" + name }
	func consoleSocket(_ index: Int) -> String { dir + "/hvc\(index).sock" }

	static func boot(_ kind: THGuestKind, agent: LabAgent) async throws -> THSpikeGuest {
		let image = image(kind)
		guard FileManager.default.fileExists(atPath: image.path) else {
			try Test.cancel(Comment(rawValue: image.recipe))
		}
		guard let mac = try await THMac.start(bind: .loopback, scope: agent.scope) else {
			throw LabError.specInvalid("no lab sshd on loopback")
		}
		let carrier: THVM
		do {
			carrier = try await THVM.create(
				LabVMSpec(name: "\(kind.stem) carrier", boot: .alpine(), consolePorts: 1,
					devices: [.guestSetup]),
				on: agent)
		} catch {
			await mac.stop()
			throw error
		}
		let name = "guest-\(kind.stem)"
		do {
			try await carrier.start()
			let payload = try await THPayloadImage.make(from: carrier)
			let disk = try TH.hostDir(agent, "spike") + "/\(kind.stem).raw"
			try? FileManager.default.removeItem(atPath: disk)
			_ = try await LabFixtures.clone(image.path, as: "\(kind.stem).raw",
				into: (disk as NSString).deletingLastPathComponent)
			let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: disk))
			try handle.truncate(atOffset: UInt64(kind == .openbsd ? 8 : 4) << 30)
			try handle.close()
			try await LabScripts.check(LabScripts.runner, [
				"start", "--run", Lab.runDir, "--name", name, "--disk", disk, "--disk-ro",
				payload, "--consoles", "1", "--ssh-forward", "--lab-gateway", String(mac.port),
				"--net", "restricted", "--cpus", "2", "--mem", "1024", "--owner",
				String(getpid()),
			], timeout: 120)
			let serial = Lab.runDir + "/qemu/\(name)/serial.sock"
			THConsoleSession.pace(serial)
			let driver = try await LabConsole.connect(
				serial, transcript: "qemu-\(name)-serial-\(THCounter.next())")
			try await driver.login(
				user: "root", password: rootPassword[kind], timeout: .seconds(300))
			let guest = THSpikeGuest(
				kind: kind, agent: agent, vm: carrier, mac: mac, name: name, driver: driver)
			try await guest.prepare()
			return guest
		} catch {
			_ = try? await LabScripts.run(
				LabScripts.runner, ["stop", "--run", Lab.runDir, "--name", name, "--timeout", "10"],
				timeout: 120)
			await carrier.cleanup()
			await mac.stop()
			throw error
		}
	}

	// The route to the Mac, the user lab (doas), the payload copied from its disk.
	private func prepare() async throws {
		try await root("route add default \(QEMUGuest.gateway) >/dev/null 2>&1; true")
		if kind == .openbsd {
			try await root("echo 'permit nopass lab' > /etc/doas.conf && chmod 600 /etc/doas.conf")
		} else {
			try await root("id lab >/dev/null 2>&1 || useradd -m -s /bin/sh lab")
		}
		// The payload disk is whichever disk holds ISO9660 (NetBSD numbers virtio disks by
		// their MMIO slot: ld4 and ld5, not ld0 and ld1).
		let mounted = try await root(
			"mkdir -p /mnt/th-payload; for n in $(sysctl -n hw.disknames | tr ',' ' '); do"
				+ " n=${n%%:*}; for p in c d a; do mount -t cd9660 -o ro /dev/$n$p"
				+ " /mnt/th-payload 2>/dev/null && echo /dev/$n$p && break 2; done; done")
		guard !mounted.isEmpty else {
			throw LabError.consoleUnavailable("no payload disk in \(name)")
		}
		try await root(
			"mkdir -p \(GuestPaths.share) && cp -R /mnt/th-payload/GuestSetup"
				+ " /mnt/th-payload/GuestReport \(GuestPaths.share)/ && umount /mnt/th-payload"
				+ " && chmod -R u+w \(GuestPaths.share)")
	}

	@discardableResult
	func root(_ command: String, timeout: Duration = .seconds(300)) async throws -> String {
		let result = try await THConsoleSession.run(driver, command, timeout: timeout)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: command, status: result.status, output: result.output)
		}
		return result.output
	}

	func exec(_ command: String, user: String?, timeout: Duration) async throws
		-> (status: Int32, output: String) {
		let line = user.map { "su -l \($0) -c \(ShellQuote.single(command))" } ?? command
		return try await THConsoleSession.run(driver, line + " </dev/null 2>&1", timeout: timeout)
	}

	func asUserShell<T>(_ user: String, _ body: () async throws -> T) async throws -> T {
		try driver.send("su -l \(user)")
		try await driver.expect("[$] *$", timeout: .seconds(30))
		let result = try await body()
		try driver.send("exit")
		try await driver.expect("[#] *$", timeout: .seconds(30))
		return result
	}

	func recoverDriver() async {
		try? driver.sendRaw([0x03])
		try? await Task.sleep(for: .milliseconds(500))
		try? driver.send("")
	}

	func reboot(remount: Bool) async throws {
		try driver.send("reboot")
		try await driver.expect("login: *$", timeout: .seconds(300))
		try await driver.login(
			user: "root", password: Self.rootPassword[kind], timeout: .seconds(120))
		try await root("route add default \(QEMUGuest.gateway) >/dev/null 2>&1; true")
	}

	func shutdown() async {
		driver.close()
		_ = try? await LabScripts.run(
			LabScripts.runner, ["stop", "--run", Lab.runDir, "--name", name, "--timeout", "10"],
			timeout: 120)
		await vm.cleanup()
		await mac?.stop()
	}
}
