//
//  TFStartFailure.swift
//  MachmanLabTests
//
//  Q28: a start that failed in the engine or in Virtualization (never a guard's refusal), kept
//  with what may explain it. A lab guest's start failed with VZ's "The storage device attachment
//  is invalid." right after another VM on the same disk image was force-quit, and the run kept
//  nothing but that sentence. Each record holds the error, every writable disk's state (size,
//  lock, who has it open), the other VMs attaching it and how they stand, the Virtualization
//  services alive, the locks again a moment later, and Virtualization's own log of the last
//  minute: report/start-failures/<pid>-<n>-<vm>.txt in the run (copied with the report; lab.sh
//  lists them), summed up as a warning on the running test. The start's error is still thrown.
//

import Darwin
import Foundation
import MachmanAPI
import MachmanTestSupport
import Testing

enum TFStartFailure {
	/// A process that has a file open: its pid, command, descriptor and access ("3u").
	struct Holder: Equatable, Sendable {
		var pid: Int32
		var command: String
		var descriptor: String
	}

	/// A disk file as the failed start left it.
	struct DiskState: Sendable {
		var path: String
		var size: UInt64?
		var inode: UInt64?
		var lock: String
		var holders: [Holder]

		var lines: [String] {
			var lines = ["  \(path)"]
			if let size, let inode {
				lines.append("    \(size) bytes, inode \(inode)")
			} else {
				lines.append("    missing")
			}
			lines.append("    lock: \(lock)")
			lines.append(holders.isEmpty ? "    open in: no process" : "    open in: "
				+ holders.map { "\($0.command)[\($0.pid)] fd \($0.descriptor)" }
				.joined(separator: ", "))
			return lines
		}
	}

	/// Whether a start's error is worth a record: the engine or Virtualization failed it. A
	/// guard's refusal (a MAC or disk conflict, a busy, missing or misconfigured VM) is what rows
	/// like TGVM.startError expect, and says why on its own.
	static func isEngineFailure(_ error: Error) -> Bool {
		if error is CancellationError { return false }
		guard let error = error as? MachmanError else { return true }
		switch error.code {
		case .internalError, .virtualizationFailure, .ioFailure: return true
		default: return false
		}
	}

	/// `vm`'s failed start, kept when it failed in the engine: its config and the other VMs as
	/// `api` lists them now. The record's path, or nil when nothing was kept.
	@discardableResult
	static func record(vm: String, api: any MachmanControlling, error: Error) async -> String? {
		guard isEngineFailure(error) else { return nil }
		let info = try? await api.vm(named: vm)
		let others = ((try? await api.listVMs()) ?? []).filter { $0.name != vm }
		return await keep(vm: vm, error: error, info: info, others: others)
	}

	/// The record itself (`record` gathers its inputs): written under `reportDir`'s
	/// start-failures/ and passed to `note` in short.
	static func keep(
		vm: String, error: Error, info: VMInfo?, others: [VMInfo],
		reportDir: String = defaultReportDir, settle: Duration = .seconds(2),
		vzLog: () async -> [String] = { await vzLogLines() },
		note: (String) -> Void = { warn($0) }
	) async -> String? {
		guard isEngineFailure(error) else { return nil }
		let files = writableFiles(info)
		var states: [DiskState] = []
		for file in files { states.append(await diskState(file)) }
		var lines = [
			"\(vm)'s start failed at \(ISO8601DateFormatter().string(from: Date()))",
			"error: \(describe(error))", "",
			"writable disks (\(files.count)):",
		]
		lines += states.flatMap(\.lines)
		lines += ["", "other VMs attaching them:"]
		let sharers = others.compactMap { other -> String? in
			let theirs = Set(writableFiles(other))
			guard !theirs.isDisjoint(with: files) else { return nil }
			let busy = other.unresponsive == true ? ", not responding" : ""
			return "  \(other.name): \(other.state.rawValue)\(busy)"
		}
		lines += sharers.isEmpty ? ["  none"] : sharers
		lines += ["", "Virtualization services alive:"]
		let services = await vzServices()
		lines += services.isEmpty ? ["  none"] : services.map { "  " + $0 }
		try? await Task.sleep(for: settle)
		lines += ["", "\(settle) later:"] + files.map { "  \($0): \(lock(of: $0))" }
		let log = await vzLog()
		lines += ["", "Virtualization's log, its last minute:"] + log.map { "  " + $0 }
		// The test process's pid first: each suite of a shard runs in a process of its own, and
		// a later one's VM of the same name must not overwrite this record.
		let path = reportDir
			+ "/start-failures/\(getpid())-\(Counter.next())-\(safeName(vm)).txt"
		do {
			try FileManager.default.createDirectory(
				atPath: reportDir + "/start-failures", withIntermediateDirectories: true)
			try (lines.joined(separator: "\n") + "\n").write(
				toFile: path, atomically: true, encoding: .utf8)
		} catch let writeError {
			note("\(vm)'s start failed (\(describe(error))); its record couldn't be kept: "
				+ "\(writeError)")
			return nil
		}
		let disk = states.first.map { state -> String in
			let held = state.holders.map { "\($0.command)[\($0.pid)]" }.joined(separator: ", ")
			return "\((state.path as NSString).lastPathComponent): \(state.lock)"
				+ (held.isEmpty ? "" : ", open in \(held)")
		} ?? "no writable disk"
		note("\(vm)'s start failed: \(MachmanError.userMessage(for: error)) — \(disk); "
			+ "kept in \(path)")
		return path
	}

	static var defaultReportDir: String {
		(Lab.runDir.isEmpty ? TestEnvironment.scratch : Lab.runDir + "/") + "report"
	}

	/// The disk files a start attaches writable: enabled disks that aren't installer images.
	static func writableFiles(_ info: VMInfo?) -> [String] {
		(info?.disks ?? []).compactMap { disk in
			guard disk.type != .iso, disk.enabled != false, let path = disk.path else { return nil }
			return (path as NSString).standardizingPath
		}
	}

	/// `path`'s size, lock and holders.
	static func diskState(_ path: String) async -> DiskState {
		var info = stat()
		let found = stat(path, &info) == 0
		return DiskState(
			path: path, size: found ? UInt64(info.st_size) : nil,
			inode: found ? UInt64(info.st_ino) : nil, lock: lock(of: path),
			holders: await holders(of: path))
	}

	/// `path`'s lock as F_GETLK reports it, taking nothing: VZ keeps a disk image it attached
	/// locked, so a lock left after its VM stopped is the disk still in use. A whole-file lock
	/// (flock) has no pid to report.
	static func lock(of path: String) -> String {
		let fd = open(path, O_RDONLY)
		guard fd >= 0 else { return "can't open it: \(String(cString: strerror(errno)))" }
		defer { close(fd) }
		var query = flock()
		query.l_type = Int16(F_WRLCK)
		query.l_whence = Int16(SEEK_SET)
		guard fcntl(fd, F_GETLK, &query) == 0 else {
			return "unknown: \(String(cString: strerror(errno)))"
		}
		let by = query.l_pid > 0 ? " by pid \(query.l_pid)" : " (a whole-file lock)"
		switch Int32(query.l_type) {
		case F_UNLCK: return "unlocked"
		case F_WRLCK: return "write-locked" + by
		default: return "read-locked" + by
		}
	}

	/// The processes that have `path` open (lsof; not -b, which can't find a file by its name).
	static func holders(of path: String) async -> [Holder] {
		guard let result = try? await Subprocess.run(
			"/usr/sbin/lsof", ["-w", "-F", "pcfa", "--", path], timeout: 20)
		else { return [] }
		var holders: [Holder] = []
		var pid: Int32 = 0
		var command = ""
		for line in result.output.split(separator: "\n") {
			let value = String(line.dropFirst())
			switch line.first {
			case "p": pid = Int32(value) ?? 0
			case "c": command = value
			case "f": holders.append(Holder(pid: pid, command: command, descriptor: value))
			case "a" where !holders.isEmpty: holders[holders.count - 1].descriptor += value
			default: break
			}
		}
		return holders
	}

	/// Every Virtualization service process (one per VM a VZ client runs, any client's), with
	/// how long it has run.
	static func vzServices() async -> [String] {
		guard let result = try? await Subprocess.run(
			"/bin/ps", ["-axww", "-o", "pid=,etime=,command="], timeout: 20)
		else { return [] }
		return result.output.split(separator: "\n").compactMap { line in
			guard line.contains("com.apple.Virtualization.VirtualMachine") else { return nil }
			let parts = line.split(separator: " ", maxSplits: 2)
			guard parts.count == 3 else { return nil }
			return "pid \(parts[0]), up \(parts[1])"
		}
	}

	/// Virtualization's own log lines of the last minute, at most the newest 40.
	static func vzLogLines() async -> [String] {
		let predicate = "subsystem BEGINSWITH \"com.apple.Virtualization\""
			+ " OR process == \"com.apple.Virtualization.VirtualMachine\""
		guard let result = try? await Subprocess.run(
			"/usr/bin/log",
			["show", "--last", "1m", "--style", "compact", "--predicate", predicate],
			timeout: 90)
		else { return ["log show didn't answer"] }
		let lines = result.output.split(separator: "\n").map(String.init)
			.filter { !$0.hasPrefix("Timestamp") }
		return lines.isEmpty ? ["nothing logged"] : Array(lines.suffix(40))
	}

	static func describe(_ error: Error) -> String {
		if let error = error as? MachmanError { return "\(error.code.rawValue): \(error.message)" }
		let ns = error as NSError
		return "\(ns.domain) \(ns.code): \(MachmanError.userMessage(for: error))"
	}

	static func warn(_ text: String) {
		MachmanLogger.log(.passiveWarning, "lab: " + text)
		Issue.record(Comment(rawValue: text), severity: .warning)
	}

	private static func safeName(_ name: String) -> String {
		String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
	}

	/// This test process's record numbers.
	private enum Counter {
		private static let lock = NSLock()
		nonisolated(unsafe) private static var value = 0

		static func next() -> Int {
			lock.withLock {
				value += 1
				return value
			}
		}
	}
}
