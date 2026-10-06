//
//  LabScripts.swift
//  MachmanLabTests
//
//  The lab's guest scripts (scripts/lab, scripts/guest-regress) as the L3 tests call them:
//  one place for their paths and the environment they get. They run inside lab.sh's run
//  (MACHMAN_LAB_RUN: the slot is lab.sh's), never with the user's ssh agent or askpass.
//

import Foundation
import MachmanAPI
import MachmanTestSupport

enum LabScripts {
	static var repo: String { Lab.repoRoot }
	static var lab: String { repo + "/scripts/lab" }
	static var runner: String { lab + "/qemu/run.sh" }
	static var prepare: String { lab + "/qemu/prepare.sh" }
	static var guestLib: String { lab + "/qemu/guest-lib.sh" }
	static var sshd: String { lab + "/sshd/sshd.sh" }
	static var guestRegress: String { repo + "/scripts/guest-regress/run.sh" }
	static func guest(os: String) -> String { lab + "/guests/\(os)/guest.sh" }

	/// This process's environment for a lab script: no ssh agent or askpass to inherit, no
	/// bytecode caches written beside the scripts.
	static var environment: [String: String] {
		var env = ProcessInfo.processInfo.environment
		env["SSH_AUTH_SOCK"] = nil
		env["SSH_ASKPASS"] = nil
		env["PYTHONDONTWRITEBYTECODE"] = "1"
		return env
	}

	/// `script` with `arguments` (bash for .sh, sh for guest-regress), `timeout` seconds.
	static func run(
		_ script: String, _ arguments: [String], timeout: TimeInterval = 600,
		environment extra: [String: String] = [:]
	) async throws -> Subprocess.Result {
		let named = script.replacingOccurrences(of: repo + "/", with: "")
		return try await LabStep.run(
			"running \(named) \(arguments.joined(separator: " ").prefix(80))"
		) {
			var env = environment
			for (key, value) in extra { env[key] = value }
			let shell = script == guestRegress ? "/bin/sh" : "/bin/bash"
			return try await Subprocess.run(
				shell, [script] + arguments, environment: env, timeout: timeout)
		}
	}

	/// run, but a non-zero exit throws with the script's output; returns stdout+stderr.
	@discardableResult
	static func check(
		_ script: String, _ arguments: [String], timeout: TimeInterval = 600,
		environment extra: [String: String] = [:]
	) async throws -> String {
		let result = try await run(script, arguments, timeout: timeout, environment: extra)
		guard result.status == 0 else {
			let name = (script as NSString).lastPathComponent
			throw LabError.commandFailed(
				command: ([name] + arguments).joined(separator: " "), status: result.status,
				output: result.output)
		}
		return result.output
	}

	/// The last non-empty line of a script's output (its answer, after any chatter).
	static func lastLine(_ output: String) -> String {
		output.split(separator: "\n").last.map(String.init)?
			.trimmingCharacters(in: .whitespaces) ?? ""
	}

	static func log(_ text: String) { MachmanLogger.log(.log, "lab: \(text)") }
}

/// The lab's prepared guest images (scripts/lab/qemu/prepare.sh): packages installed once
/// per pinned base image, a baked root/lab key beside each.
enum LabGuest: String, CaseIterable, Sendable, CustomStringConvertible {
	case debian
	case debianSysv = "debian-sysv"
	case freebsd14
	case freebsd15

	var description: String { rawValue }

	/// Its scripts/lab/guests/<os> directory.
	var os: String {
		switch self {
		case .debian, .debianSysv: "debian"
		case .freebsd14, .freebsd15: "freebsd"
		}
	}

	/// The user the baked key logs in as.
	var user: String { os == "freebsd" ? "lab" : "root" }

	/// The FreeBSD release a FreeBSD image runs (freebsd-version prints "<it>-RELEASE…").
	var release: String? {
		switch self {
		case .freebsd14: "14.5"
		case .freebsd15: "15.1"
		default: nil
		}
	}

	/// The prepared image in the lab cache, prepared on a miss inside the lab run (that
	/// boots QEMU with open networking once, then never again for this pin).
	func imagePath() async throws -> String {
		let output = try await LabScripts.check(
			LabScripts.prepare, ["path", rawValue], timeout: 1800)
		return LabScripts.lastLine(output)
	}
}
