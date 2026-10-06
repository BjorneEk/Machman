//
//  TFVolumes.swift
//  MachmanLabTests
//
//  A second volume for the library rows: a sparse disk image formatted exFAT, HFS+ or APFS,
//  created and mounted ONLY under the run root (<run>/tf-volumes), attached -nobrowse (no
//  Finder, no Desktop icon), -noautoopen and -owners off (an exFAT root is root-owned 0700
//  otherwise, measured), detached at the end; the lab detaches whatever an
//  interrupted run left (sandbox_detach_images). On by default (B-2: the one-time Removable
//  Volumes prompt is accepted); MACHMAN_LAB_VOLUMES=0 opts out.
//

import Foundation
import MachmanTestSupport
import Testing

struct TFVolume: Sendable {
	enum Format: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case exfat = "ExFAT"
		case hfsPlus = "HFS+"
		case apfs = "APFS"

		var testDescription: String { rawValue }
	}

	let image: String
	let mountPoint: String

	/// hdiutil's argv for creating and attaching `name` under `root` (pure).
	static func commandLines(_ format: Format, gib: Int, name: String, root: String)
		-> (create: [String], attach: [String], image: String, mountPoint: String) {
		let dir = root + "/tf-volumes"
		let image = dir + "/\(name).sparsebundle"
		let mount = dir + "/\(name).mnt"
		return (
			["create", "-size", "\(gib)g", "-type", "SPARSEBUNDLE", "-fs", format.rawValue,
				"-volname", "TF\(name)", image],
			["attach", "-nobrowse", "-noautoopen", "-noverify", "-owners", "off",
				"-mountpoint", mount, image],
			image, mount)
	}

	static func make(_ format: Format, gib: Int, name: String) async throws -> TFVolume {
		let lines = commandLines(format, gib: gib, name: name, root: Lab.runDir)
		try FileManager.default.createDirectory(
			atPath: lines.mountPoint, withIntermediateDirectories: true)
		try await hdiutil(lines.create)
		do {
			try await hdiutil(lines.attach)
		} catch {
			try? FileManager.default.removeItem(atPath: lines.image)
			throw error
		}
		return TFVolume(image: lines.image, mountPoint: lines.mountPoint)
	}

	/// Detaches (forced when a plain detach fails) and deletes the image.
	func detach() async {
		if (try? await Self.hdiutil(["detach", mountPoint])) == nil {
			_ = try? await Self.hdiutil(["detach", "-force", mountPoint])
		}
		try? FileManager.default.removeItem(atPath: image)
	}

	/// `body` with a volume that is detached on every path.
	static func with<T>(
		_ format: Format, gib: Int, name: String, _ body: (TFVolume) async throws -> T
	) async throws -> T {
		let volume = try await make(format, gib: gib, name: name)
		do {
			let result = try await body(volume)
			await volume.detach()
			return result
		} catch {
			await volume.detach()
			throw error
		}
	}

	private static func hdiutil(_ arguments: [String]) async throws {
		let result = try await Subprocess.run("/usr/bin/hdiutil", arguments, timeout: 300)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "hdiutil " + arguments.joined(separator: " "), status: result.status,
				output: result.output)
		}
	}
}

enum TFFiles {
	/// A file of `bytes` non-zero bytes (a repeated 1 MiB block): a copy of it is a real byte
	/// copy on every volume, never a hole skipped. Written off the cooperative pool.
	static func filled(_ path: String, bytes: Int) async throws {
		let ok = await offPool { () -> Bool in
			guard FileManager.default.createFile(atPath: path, contents: nil),
				let handle = FileHandle(forWritingAtPath: path) else { return false }
			defer { try? handle.close() }
			var block = Data(count: 1 << 20)
			block.withUnsafeMutableBytes { raw in
				for index in raw.indices { raw[index] = UInt8(truncatingIfNeeded: index &* 31 | 1) }
			}
			var written = 0
			while written < bytes {
				let chunk = min(block.count, bytes - written)
				guard (try? handle.write(contentsOf: block.prefix(chunk))) != nil else {
					return false
				}
				written += chunk
			}
			return true
		}
		guard ok else { throw TFError.precondition("couldn't write \(bytes) bytes to \(path)") }
	}
}
