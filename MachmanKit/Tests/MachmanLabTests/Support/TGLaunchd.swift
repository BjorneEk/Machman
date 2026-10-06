//
//  TGLaunchd.swift
//  MachmanLabTests
//
//  The autostart rows' launchd side. Plists are the agent's own, written into the scope's
//  fake home; a job is loaded into the user's gui domain only by the launchd tier (T4),
//  only under this run's `<suite>.vm.` label and from a plist inside the run dir, and every
//  job a test loads is booted out on every path (lab.sh boots out the token's jobs again at
//  exit). The L2 rows never load a job: they replay a plist's command line as a child.
//

import Foundation
import MachmanTestSupport

enum TGLaunchd {
	static func label(_ vm: String) -> String { "\(Lab.suiteID).vm.\(vm)" }

	static func plistPath(_ scope: LabScope, _ vm: String) -> String {
		scope.homeDir + "/Library/LaunchAgents/" + label(vm) + ".plist"
	}

	struct Plist {
		var label: String
		var arguments: [String]
		var environment: [String: String]
		var runAtLoad: Bool?
		var keepAlive: Bool?
		var sessionType: String?
	}

	static func readPlist(_ path: String) throws -> Plist {
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		guard let object = try PropertyListSerialization.propertyList(from: data, format: nil)
			as? [String: Any], let label = object["Label"] as? String else {
			throw LabError.specInvalid("\(path) isn't a launchd job plist")
		}
		return Plist(
			label: label, arguments: object["ProgramArguments"] as? [String] ?? [],
			environment: object["EnvironmentVariables"] as? [String: String] ?? [:],
			runAtLoad: object["RunAtLoad"] as? Bool, keepAlive: object["KeepAlive"] as? Bool,
			sessionType: object["LimitLoadToSessionType"] as? String)
	}

	/// Refuses a job that isn't this run's: a label outside `<suite>.vm.` or a plist outside
	/// the run dir (never the user's ~/Library/LaunchAgents).
	static func check(label: String, plist: String?, suite: String = Lab.suiteID,
		runDir: String = Lab.runDir) throws {
		guard !suite.isEmpty, label.hasPrefix(suite + ".vm."), label.count > suite.count + 4
		else { throw LabError.specInvalid("not a job of this lab run: \(label)") }
		if let plist {
			let standard = (plist as NSString).standardizingPath
			guard !runDir.isEmpty, standard.hasPrefix(runDir + "/") else {
				throw LabError.specInvalid("a lab job's plist must be inside \(runDir): \(plist)")
			}
		}
	}

	static var domain: String { "gui/\(getuid())" }

	struct JobState {
		var loaded: Bool
		var pid: pid_t?
		var lastExit: Int32?
	}

	/// What `launchctl print` says of the job (not loaded when it fails).
	static func state(_ label: String) async throws -> JobState {
		try check(label: label, plist: nil)
		let result = try await Subprocess.run("/bin/launchctl", ["print", "\(domain)/\(label)"])
		guard result.status == 0 else { return JobState(loaded: false) }
		var state = JobState(loaded: true)
		for line in result.output.split(separator: "\n") {
			let text = line.trimmingCharacters(in: .whitespaces)
			if text.hasPrefix("pid = ") { state.pid = pid_t(text.dropFirst(6)) }
			if text.hasPrefix("last exit code = ") {
				// "70: EX_SOFTWARE": launchctl names a sysexits code after it.
				state.lastExit = Int32(text.dropFirst(17).prefix { $0 == "-" || $0.isNumber })
			}
		}
		return state
	}

	/// The jobs one test loaded; each is booted out when the test ends, however it ends.
	final class Jobs: @unchecked Sendable {
		private let lock = NSLock()
		private var labels: [String] = []

		func bootstrap(_ plist: String) async throws {
			let job = try TGLaunchd.readPlist(plist)
			try TGLaunchd.check(label: job.label, plist: plist)
			lock.withLock { labels.append(job.label) }
			let result = try await Subprocess.run(
				"/bin/launchctl", ["bootstrap", TGLaunchd.domain, plist])
			guard result.status == 0 else {
				throw LabError.commandFailed(
					command: "launchctl bootstrap \(job.label)", status: result.status,
					output: result.output)
			}
		}

		func bootoutAll() async {
			let all = lock.withLock { labels }
			for label in all.reversed() { await TGLaunchd.bootout(label) }
		}
	}

	static func bootout(_ label: String) async {
		guard (try? check(label: label, plist: nil)) != nil else { return }
		_ = try? await Subprocess.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
	}

	static func withJobs<T>(_ body: (Jobs) async throws -> T) async throws -> T {
		let jobs = Jobs()
		do {
			let result = try await body(jobs)
			await jobs.bootoutAll()
			return result
		} catch {
			await jobs.bootoutAll()
			throw error
		}
	}

	/// Runs the job's command line as launchd would at login, but as this process's child
	/// (T21): its arguments and environment, plus the PATH, TMPDIR, USER and LOGNAME launchd
	/// adds. Returns its exit status and output.
	static func spawnLikeLaunchd(_ plist: Plist, timeout: TimeInterval = 60) async throws
		-> Subprocess.Result {
		try check(label: plist.label, plist: nil)
		guard let executable = plist.arguments.first else {
			throw LabError.specInvalid("\(plist.label) has no ProgramArguments")
		}
		var environment = plist.environment
		let own = ProcessInfo.processInfo.environment
		environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
		environment["TMPDIR"] = own["TMPDIR"] ?? NSTemporaryDirectory()
		environment["USER"] = own["USER"]
		environment["LOGNAME"] = own["LOGNAME"]
		return try await Subprocess.run(
			executable, Array(plist.arguments.dropFirst()), environment: environment,
			timeout: timeout)
	}
}
