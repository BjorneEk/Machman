//
//  Watch.swift
//  hostwatch
//
//  The sampling audits of a lab run: windows, activation policy, active state, frontmost app
//  and the pasteboard's changeCount of every lab process, every tick. Reads only (window
//  geometry without titles, NSRunningApplication state, changeCount without contents,
//  same-uid process arguments); never creates UI.
//

import AppKit
import CoreGraphics
import Foundation

struct WindowInfo {
	var pid: Int32
	var number: Int
	var layer: Int
	var onscreen: Bool
	var bounds: CGRect
}

struct AppInfo {
	var pid: Int32
	var name: String
	var policy: NSApplication.ActivationPolicy
	var isActive: Bool
}

struct Frontmost {
	var pid: Int32
	var name: String
}

/// Everything one tick observes; the injection layer edits it before the rules see it.
struct Sample {
	var labPids: Set<Int32> = []
	var windows: [WindowInfo] = []
	var apps: [Int32: AppInfo] = [:]
	var frontmost: Frontmost?
	var changeCount = 0
	var nonLab: [String: String] = [:]
	var newApps: [Int32: String] = [:]
	var injected: Set<String> = []
}

// MARK: - samplers

func processArguments(_ pid: Int32) -> String? {
	var argmax = 0
	var size = MemoryLayout<Int>.size
	var mibMax = [CTL_KERN, KERN_ARGMAX]
	guard sysctl(&mibMax, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
	var buffer = [UInt8](repeating: 0, count: argmax)
	var length = argmax
	var mib = [CTL_KERN, KERN_PROCARGS2, pid]
	guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0, length > 0 else { return nil }
	// NULs become spaces so a token boundary class sees an end of word.
	return String(decoding: buffer[0..<length].map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
}

func allPids() -> [Int32] {
	let count = proc_listallpids(nil, 0)
	guard count > 0 else { return [] }
	var pids = [Int32](repeating: 0, count: Int(count) + 64)
	let used = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
	return used > 0 ? Array(pids.prefix(Int(used))).filter { $0 > 0 } : []
}

func processPath(_ pid: Int32) -> String? {
	var buffer = [CChar](repeating: 0, count: 4096)
	return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
}

func isAlive(_ pid: Int32) -> Bool {
	kill(pid, 0) == 0 || errno == EPERM
}

func pidFilePids(run: String) -> [Int32] {
	let names = (try? FileManager.default.contentsOfDirectory(atPath: run + "/pids")) ?? []
	return names.filter { $0.hasSuffix(".pid") }.compactMap { name in
		let text = (try? String(contentsOfFile: run + "/pids/" + name, encoding: .utf8)) ?? ""
		let digits = text.split(whereSeparator: { !$0.isNumber }).first
		return digits.flatMap { Int32($0) }
	}.filter(isAlive)
}

func sampleWindows() -> [WindowInfo] {
	let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
	return list.compactMap { item in
		guard let pid = item[kCGWindowOwnerPID as String] as? Int32 else { return nil }
		var bounds = CGRect.zero
		if let dictionary = item[kCGWindowBounds as String] as? NSDictionary {
			bounds = CGRect(dictionaryRepresentation: dictionary) ?? .zero
		}
		return WindowInfo(
			pid: pid, number: item[kCGWindowNumber as String] as? Int ?? 0,
			layer: item[kCGWindowLayer as String] as? Int ?? 0,
			onscreen: item[kCGWindowIsOnscreen as String] as? Bool ?? false, bounds: bounds)
	}
}

// MARK: - the watcher

final class Watcher {
	let token: String
	let run: String
	let out: String
	let interval: Double
	var injections: [String]
	let injectAfter: Int
	let start = Date()
	let selfPid = getpid()

	var events: [(t: Double, level: String, audit: String, pid: Int32, detail: String)] = []
	var reported: Set<String> = []
	var ticks = 0
	var samples = 0
	var baselineCount = NSPasteboard.general.changeCount
	var pasteboardOffset = 0
	var lastFront: Int32?
	var finished = false
	var nonLab: [String: String] = [:]
	var timer: Timer?
	var signalSource: DispatchSourceSignal?

	init(token: String, run: String, out: String, interval: Double, injections: [String],
		injectAfter: Int) {
		self.token = token
		self.run = run
		self.out = out
		self.interval = interval
		self.injections = injections
		self.injectAfter = injectAfter
	}

	func labPids() -> Set<Int32> {
		var found = Set(pidFilePids(run: run))
		let needles = ["Machman.test-" + token, "/mml." + token]
		for pid in allPids() where pid != selfPid {
			guard let text = processArguments(pid) else { continue }
			for needle in needles where matches(text, needle) {
				found.insert(pid)
			}
		}
		found.remove(selfPid)
		return found
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

	func takeSample() -> Sample {
		var sample = Sample()
		sample.labPids = labPids()
		sample.windows = sampleWindows()
		for pid in sample.labPids {
			if let app = NSRunningApplication(processIdentifier: pid) {
				sample.apps[pid] = AppInfo(
					pid: pid, name: app.bundleIdentifier ?? app.localizedName ?? "pid \(pid)",
					policy: app.activationPolicy, isActive: app.isActive)
			}
		}
		if let front = NSWorkspace.shared.frontmostApplication {
			sample.frontmost = Frontmost(
				pid: front.processIdentifier,
				name: front.bundleIdentifier ?? front.localizedName ?? "pid \(front.processIdentifier)")
		}
		sample.changeCount = NSPasteboard.general.changeCount
		for pid in allPids() where !sample.labPids.contains(pid) && pid != selfPid {
			if let path = processPath(pid), path.range(
				of: "/Machman[A-Za-z]*\\.app/Contents/MacOS/[^/]+$", options: .regularExpression) != nil {
				sample.nonLab[String(pid)] = path
			}
		}
		for app in NSWorkspace.shared.runningApplications
		where app.activationPolicy == .regular && (app.launchDate ?? .distantPast) > start
			&& !sample.labPids.contains(app.processIdentifier) {
			sample.newApps[app.processIdentifier] =
				app.bundleIdentifier ?? app.localizedName ?? "pid \(app.processIdentifier)"
		}
		return sample
	}

	/// The injection layer: provoked breaches, once each, after `injectAfter` ticks.
	func inject(_ sample: inout Sample) {
		if ticks == injectAfter {
			for kind in injections {
				switch kind {
				case "window":
					sample.labPids.insert(-1)
					sample.windows.append(WindowInfo(
						pid: -1, number: 0, layer: 0, onscreen: true,
						bounds: CGRect(x: 0, y: 0, width: 1, height: 1)))
					sample.apps[-1] = AppInfo(pid: -1, name: "injected", policy: .accessory,
						isActive: false)
					sample.injected.insert("window")
				case "policy":
					sample.labPids.insert(-1)
					sample.apps[-1] = AppInfo(pid: -1, name: "injected", policy: .regular,
						isActive: false)
					sample.injected.insert("policy")
				case "frontmost":
					sample.labPids.insert(-1)
					sample.frontmost = Frontmost(pid: -1, name: "injected")
					sample.injected.insert("frontmost")
				case "pasteboard":
					pasteboardOffset += 1
					sample.labPids.insert(-1)
					sample.frontmost = Frontmost(pid: -1, name: "injected")
					sample.injected.insert("pasteboard")
				case "pasteboard-user":
					pasteboardOffset += 1
					sample.frontmost = Frontmost(pid: -2, name: "user-app")
					sample.injected.insert("pasteboard")
				default: break
				}
			}
		}
		sample.changeCount += pasteboardOffset
	}

	func record(_ level: String, _ audit: String, _ pid: Int32, _ detail: String, key: String) {
		guard reported.insert(level + ":" + key).inserted else { return }
		let t = Date().timeIntervalSince(start)
		events.append((t, level, audit, pid, detail))
		let object: [String: Any] = [
			"t": (t * 1000).rounded() / 1000, "level": level, "audit": audit, "pid": Int(pid),
			"detail": detail,
		]
		if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
			let handle = FileHandle(forWritingAtPath: out + "/watch.jsonl") {
			handle.seekToEndOfFile()
			handle.write(data + Data("\n".utf8))
			try? handle.close()
		}
	}

	func apply(_ sample: Sample) {
		let suffix = { (audit: String) in sample.injected.contains(audit) ? " (injected)" : "" }
		func name(_ pid: Int32) -> String { sample.apps[pid]?.name ?? "pid \(pid)" }
		for window in sample.windows where sample.labPids.contains(window.pid) {
			let b = window.bounds
			let place = "at \(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height))"
			let detail = "pid \(window.pid) (\(name(window.pid))) window \(window.number) layer "
				+ "\(window.layer) \(place)" + suffix("window")
			if window.onscreen {
				record("breach", "window", window.pid, detail, key: "w\(window.pid).\(window.number)")
			} else {
				record("note", "window", window.pid, detail + " (off screen)",
					key: "w\(window.pid).\(window.number)")
			}
		}
		for (pid, app) in sample.apps {
			if app.policy == .regular {
				record("breach", "policy", pid,
					"pid \(pid) (\(app.name)) has a Dock icon (regular)" + suffix("policy"),
					key: "p\(pid)")
			}
			if app.isActive {
				record("breach", "active", pid, "pid \(pid) (\(app.name)) became active",
					key: "a\(pid)")
			}
		}
		if let front = sample.frontmost {
			if front.pid != lastFront {
				lastFront = front.pid
				record("note", "frontmost", front.pid, "\(front.name) (\(front.pid))",
					key: "f\(front.pid).\(ticks)")
			}
			if sample.labPids.contains(front.pid) {
				record("breach", "frontmost", front.pid,
					"pid \(front.pid) (\(front.name)) is frontmost" + suffix("frontmost"),
					key: "front\(front.pid)")
			}
		}
		if sample.changeCount != baselineCount {
			let t = Date().timeIntervalSince(start)
			let who = sample.frontmost
			let timeText = String(format: "%.1f", t)
			let detail = "changeCount \(baselineCount) → \(sample.changeCount) at \(timeText) s "
				+ "while \(who?.name ?? "no app") was frontmost" + suffix("pasteboard")
			if let who, !sample.labPids.contains(who.pid) {
				record("note", "pasteboard", who.pid, detail + " (user copy?)",
					key: "pb\(sample.changeCount)")
			} else {
				record("breach", "pasteboard", who?.pid ?? 0, detail, key: "pb\(sample.changeCount)")
			}
			baselineCount = sample.changeCount
		}
		for (pid, app) in sample.newApps {
			record("warn", "new-app", pid, "\(app) (\(pid)) launched during the run", key: "n\(pid)")
		}
		for (pid, path) in sample.nonLab { nonLab[pid] = path }
	}

	func tick() {
		guard !finished else { return }
		if FileManager.default.fileExists(atPath: out + "/stop") {
			finish()
			return
		}
		var sample = takeSample()
		inject(&sample)
		apply(sample)
		samples += 1
		ticks += 1
		if samples == 1 {
			FileManager.default.createFile(atPath: out + "/started", contents: Data())
		}
	}

	func finish() {
		guard !finished else { return }
		finished = true
		timer?.invalidate()
		var lines = events.map { "\($0.level.uppercased()) \($0.audit) \($0.detail)" }
		for audit in ["window", "policy", "active", "frontmost", "pasteboard"]
		where !events.contains(where: { $0.level == "breach" && $0.audit == audit }) {
			lines.append("OK \(audit)")
		}
		lines.append("SAMPLES \(samples)")
		emit(lines, to: out + "/summary.txt")
		emit(nonLab.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" },
			to: out + "/non-lab-machman.txt")
		exit(events.contains { $0.level == "breach" } ? 3 : 0)
	}
}

/// `watch --token T --run R --out DIR [--interval 0.5] [--inject KIND]... [--inject-after 2]`
func runWatch(_ args: [String]) {
	guard let token = value("--token", in: args), let run = value("--run", in: args),
		let out = value("--out", in: args)
	else { exit(64) }
	try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
	FileManager.default.createFile(atPath: out + "/watch.jsonl", contents: Data())
	let watcher = Watcher(
		token: token, run: run, out: out,
		interval: Double(value("--interval", in: args) ?? "0.5") ?? 0.5,
		injections: values("--inject", in: args),
		injectAfter: Int(value("--inject-after", in: args) ?? "2") ?? 2)
	signal(SIGTERM, SIG_IGN)
	let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
	source.setEventHandler { watcher.finish() }
	source.resume()
	watcher.signalSource = source
	watcher.timer = Timer.scheduledTimer(withTimeInterval: watcher.interval, repeats: true) { _ in
		watcher.tick()
	}
	RunLoop.main.run()
}
