//
//  TFSSHSessions.swift
//  MachmanLabTests
//
//  An ssh session tab's target for the engine rows: the lab sshd on 127.0.0.1 standing in
//  for a guest's sshd (T12: no TCP from a test process to a guest). The VM is synthetic, its
//  ssh state real: a key made in the sandbox, the lab sshd's host key pinned under the VM's
//  alias, and the product's own argv (SSHCommand.arguments) behind a host-quiet prefix —
//  -F /dev/null and no agent, no global known_hosts, no host-key updates, no multiplexing —
//  so nothing of the user's ~/.ssh is read or written (ssh finds ~ through getpwuid).
//

import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanDesktopCore

struct TFSSHTarget: Sendable {
	static let vmName = "tf-ssh"
	static let alias = "tf-ssh.machman"

	let sshd: LabSSHD
	let vm: VMInfo
	let keyPath: String

	/// A target on `sshd` (loopback only); `authorized` false leaves the key unknown to it.
	static func make(sshd: LabSSHD, dir: String, authorized: Bool = true) async throws
		-> TFSSHTarget {
		guard sshd.host == "127.0.0.1" else {
			throw TFError.precondition("the lab sshd for session rows must be on loopback")
		}
		let key = try await TFReport.keyPair(in: dir, name: "id_ed25519")
		if authorized { try await sshd.authorize(publicKey: key.publicLine) }
		let knownHosts = dir + "/known_hosts"
		try (try sshd.knownHostsLine(for: alias) + "\n")
			.write(toFile: knownHosts, atomically: true, encoding: .utf8)
		let hostKey = try String(contentsOfFile: sshd.hostKeyPath, encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let ssh = SSHInfo(
			guestUser: LabSSHD.macUser, guestHostKey: hostKey, alias: alias,
			identityFilePath: key.privatePath, knownHostsPath: knownHosts, address: sshd.host)
		return TFSSHTarget(sshd: sshd, vm: syntheticVM(ssh), keyPath: key.privatePath)
	}

	/// A running VM that is nothing but its ssh state.
	static func syntheticVM(_ ssh: SSHInfo) -> VMInfo {
		VMInfo(
			name: vmName, state: .running, created: Date(), lastRan: nil, cpuCount: 1,
			memoryBytes: 1 << 30, macAddress: nil, disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil, minCPUCount: nil,
				minMemoryBytes: nil),
			ssh: ssh)
	}

	/// The argv a session tab runs: the host-quiet prefix, the port, the product's own (pure).
	static func arguments(for vm: VMInfo, port: Int) -> [String]? {
		SSHCommand.arguments(for: vm).map { TFSSH.hostQuietPrefix + ["-p", String(port)] + $0 }
	}

	func arguments() throws -> [String] {
		guard let argv = Self.arguments(for: vm, port: sshd.port) else {
			throw TFError.precondition("SSHCommand made no argv for the synthetic VM")
		}
		return argv
	}
}

enum TFSSH {
	/// Options that keep a test's ssh off the user's ~/.ssh and ssh-agent. ssh takes the first
	/// value of an option, so these come before the product's own.
	static let hostQuietPrefix = [
		"-F", "/dev/null", "-o", "IdentityAgent=none", "-o", "GlobalKnownHostsFile=/dev/null",
		"-o", "UpdateHostKeys=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
		"-o", "AddKeysToAgent=no",
	]

	/// The lab sshd's pid (<run>/pids/sshd.pid).
	static func sshdPID() -> pid_t? {
		let text = try? String(contentsOfFile: Lab.pidsDir + "/sshd.pid", encoding: .utf8)
		return text.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
	}

	/// The sessions the lab sshd runs now: its descendants.
	static func sessionPIDs() async throws -> [pid_t] {
		guard let sshd = sshdPID() else { return [] }
		return try await TFProcess.descendants(of: sshd)
	}

	/// The sshd-session processes among them (the per-connection server processes).
	static func sshdSessions() async throws -> [pid_t] {
		try await sessionPIDs().filter {
			TFProcess.path(of: $0)?.hasSuffix("/sshd-session") == true
		}
	}

	/// ssh clients whose argv names `key` (this target's sandbox key: no other ssh matches).
	static func clientPIDs(key: String) async throws -> [pid_t] {
		try await TFProcess.pids(argvContaining: key).filter {
			TFProcess.path(of: $0) == "/usr/bin/ssh"
		}
	}

	/// What runs now, for a failure's message: the lab sshd's descendants and the ssh
	/// clients of `key`, one `pid ppid command` line each, and the sshd's log tail.
	static func describe(key: String) async -> String {
		let rows = (try? await TFProcess.table()) ?? []
		let sshd = sshdPID()
		let tree = sshd.map { TFProcess.descendants(of: $0, in: rows) } ?? []
		let lines = rows.filter { tree.contains($0.pid) || $0.command.contains(key) }
			.map { "\($0.pid) \($0.ppid) \($0.command)" }
		let log = (try? String(contentsOfFile: Lab.runDir + "/sshd/sshd.log", encoding: .utf8))
			.map { $0.split(separator: "\n").suffix(15).joined(separator: "\n") } ?? ""
		return "processes:\n" + lines.joined(separator: "\n") + "\nsshd.log:\n" + log
	}

	/// `sig` to the lab sshd's own sshd-session children only; returns the pids signalled.
	@discardableResult
	static func signalSessions(_ sig: Int32) async throws -> [pid_t] {
		guard let sshd = sshdPID() else { return [] }
		// All checked before any is signalled: a killed monitor's child is reparented at
		// once, and would no longer read as the lab sshd's.
		var eligible: [pid_t] = []
		for pid in try await sshdSessions()
		where await TFProcess.isLabSSHDSession(pid, labSSHD: sshd) {
			eligible.append(pid)
		}
		return eligible.filter { kill($0, sig) == 0 }
	}
}
