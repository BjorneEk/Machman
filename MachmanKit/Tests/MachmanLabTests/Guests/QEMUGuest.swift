//
//  QEMUGuest.swift
//  MachmanLabTests
//
//  A lab guest under the headless QEMU runner (scripts/lab/qemu/run.sh, through the guest's
//  scripts/lab/guests/<os>/guest.sh): a clone of its prepared image in the lab run, restricted
//  networking, ssh only through the 127.0.0.1 forward with the image's baked key, consoles on
//  UNIX sockets. Its default route is the lab gateway 10.0.2.100, whose port 22 is the lab
//  sshd (or nothing): the "Mac" a guest script finds is never this Mac's real sshd.
//

import Foundation
import MachmanTestSupport

struct QEMUGuest: Sendable {
	/// The guest's default gateway in the lab: port 22 forwards to the lab sshd, if any.
	static let gateway = "10.0.2.100"

	let guest: LabGuest
	let name: String
	/// <run>/qemu/<name>: sockets, logs, guest.env, the clone and the key.
	let dir: String

	var serialSocket: String { dir + "/serial.sock" }
	func consoleSocket(_ index: Int) -> String { dir + "/hvc\(index).sock" }

	/// Boots `guest` (the cap of two lab guests holds: run.sh refuses a third) and waits for
	/// ssh. The guest dies with this test process (run.sh's owner watchdog).
	static func boot(
		_ guest: LabGuest, name: String, labSSHD: LabSSHD? = nil, consoles: Int = 3
	) async throws -> QEMUGuest {
		var arguments = [
			"boot", guest.rawValue, "--run", Lab.runDir, "--name", name,
			"--owner", String(getpid()), "--consoles", String(consoles),
		]
		if let labSSHD { arguments += ["--lab-gateway", String(labSSHD.port)] }
		let output = try await LabScripts.check(
			LabScripts.guest(os: guest.os), arguments, timeout: 600)
		let dir = LabScripts.lastLine(output)
		LabScripts.log("\(name) (\(guest)) up in \(dir)")
		return QEMUGuest(guest: guest, name: name, dir: dir)
	}

	/// `command` over ssh as the image's user (lab with doas on FreeBSD, root on Debian).
	func ssh(_ command: String, timeout: TimeInterval = 300) async throws -> Subprocess.Result {
		let script = ". \"$1\"; guest_ssh \"$2\" \"$3\""
		return try await Subprocess.run(
			"/bin/bash", ["-c", script, "lab-ssh", LabScripts.guestLib, dir, command],
			environment: LabScripts.environment, timeout: timeout)
	}

	/// ssh, but a non-zero exit throws; returns the output without its trailing newline.
	@discardableResult
	func sshCheck(_ command: String, timeout: TimeInterval = 300) async throws -> String {
		let result = try await ssh(command, timeout: timeout)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "ssh \(name) \(command)", status: result.status, output: result.output)
		}
		return result.output.trimmingCharacters(in: .newlines)
	}

	/// The serial console (the PL011: FreeBSD's ttyu0) or virtconsole `index` (hvc<index>).
	func console(_ index: Int? = nil) async throws -> LabConsole {
		let socket = index.map(consoleSocket) ?? serialSocket
		let label = index.map { "hvc\($0)" } ?? "serial"
		return try await LabConsole.connect(socket, transcript: "qemu-\(name)-\(label)")
	}

	/// Reboots over ssh, waits for ssh to drop and come back, and puts the default route
	/// back on the lab gateway.
	func reboot() async throws {
		_ = try await ssh(
			"\(guest.os == "freebsd" ? "doas " : "")sh -c "
				+ "'nohup sh -c \"sleep 1; reboot\" >/dev/null 2>&1 </dev/null &'")
		let down = ContinuousClock.now + .seconds(60)
		while (try? await ssh("true", timeout: 15))?.status == 0 {
			if ContinuousClock.now >= down {
				throw LabError.stateTimeout(vm: name, wanted: "rebooting", last: "up")
			}
			try await Task.sleep(for: .seconds(2))
		}
		let up = ContinuousClock.now + .seconds(180)
		while (try? await ssh("true", timeout: 15))?.status != 0 {
			if ContinuousClock.now >= up {
				throw LabError.stateTimeout(vm: name, wanted: "ssh", last: "down")
			}
			try await Task.sleep(for: .seconds(2))
		}
		let route = try await LabScripts.check(LabScripts.guest(os: guest.os), ["lab-route"])
		try await sshCheck(LabScripts.lastLine(route))
	}

	/// Powers the guest off (QMP, then signals) and drops its disk clone.
	func stop() async {
		_ = try? await LabScripts.run(
			LabScripts.runner, ["stop", "--run", Lab.runDir, "--name", name, "--timeout", "10"],
			timeout: 120)
		try? FileManager.default.removeItem(atPath: dir + "/disk.raw")
	}
}

extension QEMUGuest {
	/// A guest for `body`; stopped on every path.
	static func with<T>(
		_ guest: LabGuest, name: String, labSSHD: LabSSHD? = nil, consoles: Int = 3,
		_ body: (QEMUGuest) async throws -> T
	) async throws -> T {
		let booted = try await boot(guest, name: name, labSSHD: labSSHD, consoles: consoles)
		do {
			let result = try await body(booted)
			await booted.stop()
			return result
		} catch {
			await booted.stop()
			throw error
		}
	}
}
