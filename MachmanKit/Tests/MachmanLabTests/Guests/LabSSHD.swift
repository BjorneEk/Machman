//
//  LabSSHD.swift
//  MachmanLabTests
//
//  The lab sshd (scripts/lab/sshd/sshd.sh): a user-level /usr/sbin/sshd that plays "the Mac"
//  for lab guests, inside the lab run — the Mac user only, public keys only (a password is
//  offered with password: true and can never succeed), sessions with HOME = the run's fake
//  home under sandbox-exec (writes only inside the run). lab.sh made its host key before the
//  agent started, so the Guest Setup payload pins it (MACHMAN_LAB_SSHD_HOSTKEY).
//

import Foundation

struct LabSSHD: Sendable {
	enum Bind: String, Sendable {
		/// 127.0.0.1: QEMU guests reach it through their lab gateway's port 22.
		case loopback
		/// The VZ NAT bridge address (192.168.64.1 by default), once a NAT VM made the bridge.
		case vmnet
	}

	let host: String
	let port: Int
	let root: String
	/// The fake home sessions run in (the run's home unless start named another).
	let home: String

	/// The public host key guests pin (`<root>/sshd/ssh_host_ed25519_key.pub`).
	var hostKeyPath: String { root + "/sshd/ssh_host_ed25519_key.pub" }

	/// The Mac user, the only account the lab sshd lets in.
	static var macUser: String { NSUserName() }

	/// `home`: the fake home sessions run in and whose .ssh/authorized_keys sshd reads (inside
	/// the run root; default the run's home) — an agent scope's home, where the product writes
	/// its reverse approvals.
	static func start(
		bind: Bind = .loopback, password: Bool = false, home: String? = nil
	) async throws -> LabSSHD {
		var arguments = ["start", "--run", Lab.runDir, "--bind", bind.rawValue]
		if password { arguments.append("--password") }
		if let home { arguments += ["--home", home] }
		let output = try await LabScripts.check(LabScripts.sshd, arguments, timeout: 120)
		let address = LabScripts.lastLine(output)
		guard let colon = address.lastIndex(of: ":"),
			let port = Int(address[address.index(after: colon)...])
		else {
			throw LabError.commandFailed(command: "sshd.sh start", status: 0, output: output)
		}
		LabScripts.log("lab sshd on \(address)")
		return LabSSHD(
			host: String(address[..<colon]), port: port, root: Lab.runDir,
			home: home ?? Lab.runDir + "/home")
	}

	/// Lets `publicKey` (one OpenSSH public key line) log in as the Mac user.
	func authorize(publicKey: String) async throws {
		let file = root + "/sshd/authorize-\(UUID().uuidString).pub"
		try (publicKey.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
			.write(toFile: file, atomically: true, encoding: .utf8)
		try await LabScripts.check(LabScripts.sshd, ["authorize", root, file])
		try? FileManager.default.removeItem(atPath: file)
	}

	/// The host key as a known_hosts entry for `name` (e.g. the guest's gateway).
	func knownHostsLine(for name: String) throws -> String {
		let key = try String(contentsOfFile: hostKeyPath, encoding: .utf8)
			.split(separator: " ").prefix(2).joined(separator: " ")
		return "\(name) \(key)"
	}

	func stop() async {
		_ = try? await LabScripts.run(LabScripts.sshd, ["stop", root], timeout: 60)
	}

	/// sshd.sh doctor: whether a bridge listener would make the Application Firewall prompt
	/// (then the VZ tests skip with the doctor's output as the reason).
	static func doctor() async -> (bridgeOK: Bool, output: String) {
		let output = (try? await LabScripts.run(LabScripts.sshd, ["doctor"], timeout: 60))?
			.output ?? "sshd.sh doctor did not run"
		return (output.contains("doctor: ok"), output)
	}
}

extension LabSSHD {
	/// A lab sshd for `body`; stopped on every path.
	static func with<T>(
		bind: Bind = .loopback, password: Bool = false, home: String? = nil,
		_ body: (LabSSHD) async throws -> T
	) async throws -> T {
		let sshd = try await start(bind: bind, password: password, home: home)
		do {
			let result = try await body(sshd)
			await sshd.stop()
			return result
		} catch {
			await sshd.stop()
			throw error
		}
	}
}
