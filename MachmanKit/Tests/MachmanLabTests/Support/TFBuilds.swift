//
//  TFBuilds.swift
//  MachmanLabTests
//
//  Another version of THIS build, for the version-skew rows: an APFS clone of the built
//  MachmanDesktop.app under the run root with the agent's and the vmhost's version keys
//  patched, re-signed ad hoc with each bundle's own entitlements (hardened runtime is off in
//  Debug, so the ad-hoc code loads its ad-hoc dylibs; the public virtualization entitlement
//  needs no team). Launch Services registers a copy when it launches, so every copy is
//  unregistered at the end (unregisterAll), and the copies go with the run root. An ad-hoc
//  identity is new each build: a copy never touches a disk-image volume or a guest's network.
//

import Foundation
import MachmanAPI
import MachmanTestSupport

enum TFBuilds {
	static let agentPath = "Contents/Library/LoginItems/MachmanAgent.app"
	static let vmhostPath = "Contents/Library/MachmanVMHost.app"
	static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
		+ "LaunchServices.framework/Support/lsregister"

	private static let lock = NSLock()
	nonisolated(unsafe) private static var made: [String: URL] = [:]

	/// This build's version (its agent's CFBundleShortVersionString).
	static var current: String {
		let url = URL(fileURLWithPath: Lab.productsDir + "/MachmanDesktop.app/" + agentPath)
		return (Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
	}

	// MARK: pure

	/// One patch below (x.y.z → x.y.(z-1)), or the minor below at .99 when z is 0.
	static func olderVersion(than version: String) -> String {
		let parts = version.split(separator: ".").compactMap { Int($0) }
		guard parts.count == 3 else { return "0.0.1" }
		if parts[2] > 0 { return "\(parts[0]).\(parts[1]).\(parts[2] - 1)" }
		if parts[1] > 0 { return "\(parts[0]).\(parts[1] - 1).99" }
		return "\(max(parts[0] - 1, 0)).99.99"
	}

	/// The same minor's .99: newer than any release of it.
	static func newerVersion(than version: String) -> String {
		let parts = version.split(separator: ".").compactMap { Int($0) }
		guard parts.count >= 2 else { return "99.0.0" }
		return "\(parts[0]).\(parts[1]).99"
	}

	/// An Info.plist with its two version keys set to `version`; nothing else changes.
	static func patchPlist(_ plist: [String: Any], version: String) -> [String: Any] {
		var patched = plist
		patched["CFBundleShortVersionString"] = version
		patched["CFBundleVersion"] = version
		return patched
	}

	// MARK: copies

	/// The copy's agent app (memoized per version for the run).
	static func agentApp(_ version: String) async throws -> URL {
		try await copy(version).appendingPathComponent(agentPath)
	}

	/// A MachmanDesktop.app of this build reporting `version`, under <run>/tf-builds.
	static func copy(_ version: String) async throws -> URL {
		if let done = lock.withLock({ made[version] }) { return done }
		let source = Lab.productsDir + "/MachmanDesktop.app"
		let dir = Lab.runDir + "/tf-builds/" + version
		try? FileManager.default.removeItem(atPath: dir)
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		try await run("/bin/cp", ["-cR", source, dir + "/"])
		let app = URL(fileURLWithPath: dir + "/MachmanDesktop.app")
		for bundle in [vmhostPath, agentPath] {
			let url = app.appendingPathComponent(bundle)
			let info = url.appendingPathComponent("Contents/Info.plist")
			let data = try Data(contentsOf: info)
			guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
				as? [String: Any] else {
				throw TFError.precondition("\(info.path) is not a dictionary")
			}
			let out = try PropertyListSerialization.data(
				fromPropertyList: patchPlist(plist, version: version), format: .xml, options: 0)
			try out.write(to: info, options: .atomic)
			try await resign(url, scratch: dir)
		}
		lock.withLock { made[version] = app }
		return app
	}

	/// Ad hoc, nested code first, the bundle last with its own extracted entitlements.
	private static func resign(_ bundle: URL, scratch: String) async throws {
		let entitlements = scratch + "/" + bundle.deletingPathExtension().lastPathComponent
			+ ".entitlements"
		let extracted = try await Subprocess.run(
			"/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", bundle.path])
		guard extracted.status == 0, let start = extracted.output.range(of: "<?xml") else {
			throw LabError.commandFailed(
				command: "codesign -d --entitlements \(bundle.path)", status: extracted.status,
				output: extracted.output)
		}
		try String(extracted.output[start.lowerBound...])
			.write(toFile: entitlements, atomically: true, encoding: .utf8)
		let fm = FileManager.default
		for sub in ["Contents/Frameworks", "Contents/MacOS"] {
			let dir = bundle.appendingPathComponent(sub).path
			for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
			where name.hasSuffix(".dylib") {
				try await run("/usr/bin/codesign", ["--force", "--sign", "-", dir + "/" + name])
			}
		}
		try await run("/usr/bin/codesign", [
			"--force", "--sign", "-", "--entitlements", entitlements,
			"--generate-entitlement-der", bundle.path,
		])
		try await run("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
	}

	/// lsregister -u for every copy this run made.
	static func unregisterAll() async {
		let copies = lock.withLock { Array(made.values) }
		for app in copies {
			for bundle in [agentPath, vmhostPath, ""] {
				let path = bundle.isEmpty ? app.path : app.appendingPathComponent(bundle).path
				_ = try? await Subprocess.run(lsregister, ["-u", path])
			}
		}
	}

	private static func run(_ tool: String, _ arguments: [String]) async throws {
		let result = try await Subprocess.run(tool, arguments, timeout: 300)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: ([tool] + arguments).joined(separator: " "), status: result.status,
				output: result.output)
		}
	}
}
