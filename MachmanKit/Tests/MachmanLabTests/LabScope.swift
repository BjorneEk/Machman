//
//  LabScope.swift
//  MachmanLabTests
//
//  One agent scope: its own library, fake home, images dir, prompt answers and control socket
//  under the run's scopes/<NN>/, so a failed test leaves nothing for the next one. A relaunch
//  inside the scope reuses them (the re-adoption rows).
//

import Foundation

struct LabScope: Sendable {
	let id: String
	let dir: String
	let dataDir: String
	let homeDir: String
	let imagesDir: String
	let answersPath: String
	let controlPath: String

	private static let counter = NSLock()
	nonisolated(unsafe) private static var next = 1

	/// A fresh scope: the next free two-digit id under `scopesDir`.
	static func make(in scopesDir: String = Lab.scopesDir) throws -> LabScope {
		let manager = FileManager.default
		try manager.createDirectory(atPath: scopesDir, withIntermediateDirectories: true)
		while true {
			let n = counter.withLock { () -> Int in
				defer { next += 1 }
				return next
			}
			let id = String(format: "%02d", n)
			let dir = scopesDir + "/" + id
			if manager.fileExists(atPath: dir) { continue }
			try manager.createDirectory(atPath: dir, withIntermediateDirectories: false)
			for sub in ["data", "home", "images"] {
				try manager.createDirectory(
					atPath: dir + "/" + sub, withIntermediateDirectories: false)
			}
			let scope = LabScope(
				id: id, dir: dir, dataDir: dir + "/data", homeDir: dir + "/home",
				imagesDir: dir + "/images", answersPath: dir + "/answers.json",
				controlPath: dir + "/agent.ctl")
			try scope.writeAnswers([:])
			return scope
		}
	}

	/// Atomically, as the agent re-reads the file at every prompt.
	func writeAnswers(_ answers: [String: Any]) throws {
		let data = try JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys])
		try data.write(to: URL(fileURLWithPath: answersPath), options: .atomic)
	}
}
