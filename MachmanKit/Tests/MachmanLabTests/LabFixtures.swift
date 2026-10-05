//
//  LabFixtures.swift
//  MachmanLabTests
//
//  The cached fixtures (scripts/lab/fetch.sh). A cached file is read-only and never booted in
//  place: every VM gets an APFS clone in its scope's images dir.
//

import Foundation
import MachmanAPI
import MachmanTestSupport

enum LabFixtures {
	/// The cached fixture `name`, or fixtureMissing naming the fetch command.
	static func path(_ name: String, cache: String = Lab.cacheDir) throws -> String {
		let file = cache + "/fixtures/" + name
		let manager = FileManager.default
		guard manager.fileExists(atPath: file), manager.fileExists(atPath: file + ".stamp") else {
			throw LabError.fixtureMissing(name: name)
		}
		return file
	}

	/// A writable clone (cp -c; a plain copy when the volume can't clone) as `base` in `dir`.
	static func clone(_ source: String, as base: String, into dir: String) async throws -> String {
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let destination = dir + "/" + base
		var result = try await Subprocess.run("/bin/cp", ["-c", source, destination])
		if result.status != 0 {
			result = try await Subprocess.run("/bin/cp", [source, destination])
			if result.status != 0 {
				throw LabError.commandFailed(
					command: "cp \(source)", status: result.status, output: result.output)
			}
			MachmanLogger.log(.passiveWarning, "lab: \(source) couldn't be cloned; copied instead")
		}
		chmod(destination, 0o644)
		return destination
	}

	struct Alpine: Sendable {
		let kernel: String
		let initramfs: String
		let version: String
	}

	/// The Alpine lab guest: kernel and initramfs paths and the kernel version, built (and
	/// cached) by scripts/lab/guests/alpine/build.sh.
	static func alpine() async throws -> Alpine {
		let script = Lab.repoRoot + "/scripts/lab/guests/alpine/build.sh"
		let result = try await Subprocess.run(
			"/bin/bash", [script, "path"],
			environment: ProcessInfo.processInfo.environment, timeout: 900)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "build.sh path", status: result.status, output: result.output)
		}
		var values: [String: String] = [:]
		for line in result.output.split(separator: "\n") {
			guard let equals = line.firstIndex(of: "=") else { continue }
			values[String(line[..<equals])] = String(line[line.index(after: equals)...])
		}
		guard let kernel = values["kernel"], let initramfs = values["initramfs"],
			let version = values["version"]
		else {
			throw LabError.commandFailed(
				command: "build.sh path", status: 0, output: "no kernel= initramfs= version=")
		}
		return Alpine(kernel: kernel, initramfs: initramfs, version: version)
	}
}
