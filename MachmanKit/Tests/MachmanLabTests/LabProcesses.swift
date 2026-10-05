//
//  LabProcesses.swift
//  MachmanLabTests
//
//  The run's pid files: <pids>/<kind>-<name>.pid for every agent, vmhost and QEMU the lab
//  started. lab.sh's audits and sweeps read them, and the cap of two guests counts them.
//

import Foundation

enum LabProcesses {
	static func pidFile(kind: String, name: String, in dir: String = Lab.pidsDir) -> String {
		let safe = String(name.map { c in
			c.isASCII && (c.isLetter || c.isNumber || "._-".contains(c)) ? c : "_"
		})
		return dir + "/\(kind)-\(safe).pid"
	}

	static func writePid(_ pid: pid_t, kind: String, name: String, in dir: String = Lab.pidsDir)
		throws {
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		try "\(pid)\n".write(
			toFile: pidFile(kind: kind, name: name, in: dir), atomically: true, encoding: .utf8)
	}

	static func removePid(kind: String, name: String, in dir: String = Lab.pidsDir) {
		try? FileManager.default.removeItem(atPath: pidFile(kind: kind, name: name, in: dir))
	}

	static func isAlive(_ pid: pid_t) -> Bool {
		kill(pid, 0) == 0 || errno == EPERM
	}

	/// Live guests: alive pids in qemu-*.pid and vmhost-*.pid.
	static func liveGuestCount(in dir: String = Lab.pidsDir) -> Int {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
		let guests = names.filter {
			($0.hasPrefix("qemu-") || $0.hasPrefix("vmhost-")) && $0.hasSuffix(".pid")
		}
		return guests.filter { name in
				let text = (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)) ?? ""
				let digits = text.split(whereSeparator: { !$0.isNumber }).first
				guard let pid = digits.flatMap({ pid_t($0) }) else { return false }
				return isAlive(pid)
			}.count
	}

	/// Pids named by `<kind>-<prefix>*.pid`.
	static func pids(kind: String, namePrefix: String, in dir: String = Lab.pidsDir) -> [pid_t] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
		return names.filter { $0.hasPrefix("\(kind)-\(namePrefix)") && $0.hasSuffix(".pid") }
			.compactMap { name in
				let text = (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)) ?? ""
				return text.split(whereSeparator: { !$0.isNumber }).first.flatMap { pid_t($0) }
			}
	}

	static func waitForExit(_ pid: pid_t, timeout: Duration) async -> Bool {
		let deadline = ContinuousClock.now + timeout
		while isAlive(pid) {
			if ContinuousClock.now >= deadline { return false }
			try? await Task.sleep(for: .milliseconds(100))
		}
		return true
	}

	static func signal(_ pid: pid_t, _ sig: Int32) {
		kill(pid, sig)
	}
}
