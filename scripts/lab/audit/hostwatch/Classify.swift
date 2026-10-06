//
//  Classify.swift
//  hostwatch
//
//  Which processes are the lab's. The snapshot diff excuses a protected-path change only while
//  a NON-lab Machman process ran, so a lab process taken for a non-lab one hides a breach as a
//  warning (the first smoke run: the lab's own vmhost, missed by one tick's token scan,
//  excused the lab agent's write into the dev agent's preferences).
//
//  Every tick reads each process once, path then arguments then path again. A process is the
//  lab's when a pid file names it or its arguments or environment name this run, and it stays
//  the lab's for the run (by pid and start time): a vmhost's pid file is gone once its VM
//  stops, and its arguments stop reading while it exits. A Machman app process is non-lab only
//  on a settled, readable sighting that names no run of this token, and only if it never turns
//  out to be the lab's; one never read so stays unclassified and excuses nothing.
//

import Foundation

/// One process as one tick saw it.
struct Sighting {
	var pid: Int32
	/// Start time in microseconds: with the pid, the process's identity across ticks (an exec
	/// keeps both). nil when it can't be read.
	var start: UInt64?
	var path: String?
	/// argv and environment, NULs as spaces; nil while the kernel can't hand them out (a
	/// process tearing down its address space at exit still has a path).
	var arguments: String?
	/// The path read the same before and after the arguments: no exec in between (launchd's
	/// xpcproxy becoming the app).
	var settled: Bool
}

func startTime(_ pid: Int32) -> UInt64? {
	var info = proc_bsdinfo()
	let size = Int32(MemoryLayout<proc_bsdinfo>.size)
	guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
	return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

/// Every process but `skipping`, each read path, arguments, path.
func sightProcesses(skipping: Int32) -> [Sighting] {
	allPids().filter { $0 != skipping }.map { pid in
		let before = processPath(pid)
		let arguments = processArguments(pid)
		let after = processPath(pid)
		return Sighting(
			pid: pid, start: startTime(pid), path: after ?? before, arguments: arguments,
			settled: before == after)
	}
}

/// A Machman app's executable (any suite, any build).
func isMachmanApp(_ path: String) -> Bool {
	path.range(of: "/Machman[A-Za-z]*\\.app/Contents/MacOS/[^/]+$", options: .regularExpression)
		!= nil
}

struct LabClassifier {
	let needles: [String]
	/// Lab processes: pid → start time (0 when it couldn't be read).
	private(set) var lab: [Int32: UInt64] = [:]
	private(set) var labPaths: [Int32: String] = [:]
	/// Machman app processes seen settled and readable without this run's token.
	private var candidates: [Int32: (start: UInt64?, path: String)] = [:]
	/// Machman app processes not read settled yet.
	private var unread: [Int32: (start: UInt64?, path: String)] = [:]

	/// Every token of the run: a parallel lab run has one per shard.
	init(tokens: [String]) {
		needles = tokens.flatMap { ["Machman.test-" + $0, "/mml." + $0] }
	}

	/// The lab pids of this tick; remembers what it learnt for the next ones.
	mutating func classify(_ sightings: [Sighting], pidFiles: Set<Int32>) -> Set<Int32> {
		var found = Set<Int32>()
		for sighting in sightings {
			let pid = sighting.pid
			let named = sighting.arguments.map { text in needles.contains { matches(text, $0) } }
			if isLab(pid, start: sighting.start) || pidFiles.contains(pid) || named == true {
				if lab[pid] == nil || lab[pid] == 0 { lab[pid] = sighting.start ?? 0 }
				if let path = sighting.path { labPaths[pid] = path }
				found.insert(pid)
				continue
			}
			guard let path = sighting.path, isMachmanApp(path) else { continue }
			if named == false && sighting.settled {
				candidates[pid] = (sighting.start, path)
			} else if candidates[pid] == nil {
				unread[pid] = (sighting.start, path)
			}
		}
		return found
	}

	/// Once the lab's, always the lab's: the same pid and start time (or either unknown).
	func isLab(_ pid: Int32, start: UInt64?) -> Bool {
		guard let known = lab[pid] else { return false }
		return known == 0 || start == nil || start == known
	}

	/// The run's non-lab Machman processes: pid and path.
	var nonLab: [(pid: Int32, path: String)] {
		candidates.filter { !isLab($0.key, start: $0.value.start) }
			.map { ($0.key, $0.value.path) }.sorted { $0.pid < $1.pid }
	}

	/// Machman app processes never read settled and never the lab's.
	var unclassified: [(pid: Int32, path: String)] {
		unread.filter { candidates[$0.key] == nil && !isLab($0.key, start: $0.value.start) }
			.map { ($0.key, $0.value.path) }.sorted { $0.pid < $1.pid }
	}

	/// `needle` followed by a byte outside [A-Za-z0-9] or the end of the text.
	func matches(_ text: String, _ needle: String) -> Bool {
		var searchRange = text.startIndex..<text.endIndex
		while let hit = text.range(of: needle, range: searchRange) {
			if hit.upperBound == text.endIndex { return true }
			let next = text[hit.upperBound]
			if !(next.isASCII && (next.isLetter || next.isNumber)) { return true }
			searchRange = hit.upperBound..<text.endIndex
		}
		return false
	}
}
