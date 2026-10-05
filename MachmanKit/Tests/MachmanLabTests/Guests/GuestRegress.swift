//
//  GuestRegress.swift
//  MachmanLabTests
//
//  scripts/guest-regress on the lab's VM backends: the assembled Guest Setup script's
//  regression suites inside real guests, one named check per row of its --results TSV
//  (distro, suite, phase, check, pass|fail|missing). The suites and their checks, the VM table
//  and the one evaluation rule (--evaluate) stay in the script.
//

import Foundation

enum GuestRegress {
	enum Backend: String, Sendable {
		/// The prepared images under the headless QEMU runner (the script drives them).
		case qemu
		/// The prepared Debian images as Machman VMs under the lab agent (GuestRegressVZ).
		case vz
	}

	struct Check: Sendable, Equatable, CustomStringConvertible {
		let distro: String
		let suite: String
		/// run, or boot (after the guest rebooted with the run's tail installed).
		let phase: String
		let name: String
		/// pass, fail or missing.
		let status: String

		var passed: Bool { status == "pass" }
		var description: String { "\(distro)/\(suite)/\(phase) \(name): \(status)" }
	}

	/// The rows of a --results / --evaluate TSV; malformed lines drop.
	static func parse(tsv: String) -> [Check] {
		tsv.split(separator: "\n").compactMap { line in
			let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
				.map(String.init)
			guard fields.count == 5, ["pass", "fail", "missing"].contains(fields[4]) else {
				return nil
			}
			return Check(
				distro: fields[0], suite: fields[1], phase: fields[2], name: fields[3],
				status: fields[4])
		}
	}

	/// `distro`'s suites on `backend` (all of them, or just `suites`), one row per check.
	static func run(
		_ backend: Backend, distro: String, suites: [String] = []
	) async throws -> [Check] {
		switch backend {
		case .qemu: try await runQEMU(distro: distro, suites: suites)
		case .vz:
			throw LabError.specInvalid("guest-regress under VZ is not in this build yet")
		}
	}

	private static func runQEMU(distro: String, suites: [String]) async throws -> [Check] {
		let results = Lab.runDir + "/regress-qemu-\(distro)-\(UUID().uuidString.prefix(8)).tsv"
		var arguments = ["--backend", "qemu", "--jobs", "2", "--results", results]
		if !suites.isEmpty { arguments += ["--suites", suites.joined(separator: " ")] }
		let result = try await LabScripts.run(
			LabScripts.guestRegress, arguments + [distro], timeout: 2400)
		LabScripts.log("guest-regress qemu \(distro): exit \(result.status)\n\(result.output)")
		let checks = parse(tsv: (try? String(contentsOfFile: results, encoding: .utf8)) ?? "")
		// 0 and 1 (some check failed) leave rows; anything else is the harness failing.
		guard [0, 1].contains(result.status), !checks.isEmpty else {
			throw LabError.commandFailed(
				command: "guest-regress --backend qemu \(distro)", status: result.status,
				output: result.output)
		}
		return checks
	}

	/// The suites `distro` runs on a VM backend (the script's VM table).
	static func suites(for distro: String) async throws -> [String] {
		let output = try await LabScripts.check(
			LabScripts.guestRegress, ["--backend", "vz", "--list"])
		for line in output.split(separator: "\n") {
			let words = line.split(separator: " ").map(String.init)
			if words.first == distro, words.count >= 3 { return Array(words.dropFirst(2)) }
		}
		throw LabError.specInvalid("guest-regress has no VM distro \(distro)")
	}

	/// Whether `suite` has after-boot checks ("# BOOT-CHECKS:" lines).
	static func hasBootChecks(_ suite: String) -> Bool {
		let file = LabScripts.repo + "/scripts/guest-regress/suites/\(suite).sh"
		let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
		return text.split(separator: "\n").contains { $0.hasPrefix("# BOOT-CHECKS: ") }
	}

	/// The script's own rule over one output: its rows for `suite` in `phase`.
	static func evaluate(
		distro: String, suite: String, phase: String, output: String
	) async throws -> [Check] {
		let result = try await LabScripts.run(
			LabScripts.guestRegress, ["--evaluate", suite, phase, output],
			environment: ["REGRESS_DISTRO": distro])
		let checks = parse(tsv: result.output)
		guard [0, 1].contains(result.status), !checks.isEmpty else {
			throw LabError.commandFailed(
				command: "guest-regress --evaluate \(suite) \(phase)", status: result.status,
				output: result.output)
		}
		return checks
	}
}
