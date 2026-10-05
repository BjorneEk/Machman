//
//  TGVolume.swift
//  MachmanLabTests
//
//  A second volume for the cross-volume rows: a sparse APFS disk image under the run dir,
//  attached with -nobrowse (no Finder window or Desktop icon) at a mount point inside the
//  run dir, detached when the test ends (lab.sh's lab_detach_images is the backstop).
//  MACHMAN_LAB_VOLUMES=0 opts a run out (B-2): these tests then skip.
//

import Foundation
import MachmanTestSupport

struct TGVolume: Sendable {
	let image: String
	let mountPoint: String

	/// Whether this run may attach a second volume (B-2: on unless MACHMAN_LAB_VOLUMES=0).
	static var enabled: Bool { Lab.environment["MACHMAN_LAB_VOLUMES"] != "0" }

	/// The non-zero size of a "big" image: 1 GiB, a real byte copy across volumes (T29).
	static let bigImageBytes = 1 << 30

	static var volumesDir: String { Lab.runDir + "/vols" }

	static func make(sizeGiB: Int) async throws -> TGVolume {
		guard !Lab.runDir.isEmpty else { throw LabError.specInvalid("no lab run dir") }
		try FileManager.default.createDirectory(
			atPath: volumesDir, withIntermediateDirectories: true)
		let id = "tg-" + TG.nonce()
		let base = volumesDir + "/" + id
		let created = try await Subprocess.run(
			"/usr/bin/hdiutil",
			["create", "-quiet", "-size", "\(sizeGiB)g", "-fs", "APFS", "-type", "SPARSE",
				"-volname", "TG\(Lab.token)", base],
			timeout: 120)
		guard created.status == 0 else {
			throw LabError.commandFailed(
				command: "hdiutil create", status: created.status, output: created.output)
		}
		let volume = TGVolume(image: base + ".sparseimage", mountPoint: base + ".mnt")
		try FileManager.default.createDirectory(
			atPath: volume.mountPoint, withIntermediateDirectories: true)
		let attached = try await Subprocess.run(
			"/usr/bin/hdiutil",
			["attach", "-quiet", "-nobrowse", "-noautoopen", "-owners", "on", "-mountpoint",
				volume.mountPoint, volume.image],
			timeout: 120)
		guard attached.status == 0 else {
			throw LabError.commandFailed(
				command: "hdiutil attach", status: attached.status, output: attached.output)
		}
		return volume
	}

	func detach() async {
		let plain = try? await Subprocess.run(
			"/usr/bin/hdiutil", ["detach", "-quiet", mountPoint], timeout: 60)
		if plain?.status != 0 {
			_ = try? await Subprocess.run(
				"/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint], timeout: 60)
		}
		try? FileManager.default.removeItem(atPath: image)
	}

	/// A volume for `body`, detached on every path.
	static func with<T>(sizeGiB: Int, _ body: (TGVolume) async throws -> T) async throws -> T {
		let volume = try await make(sizeGiB: sizeGiB)
		do {
			let result = try await body(volume)
			await volume.detach()
			return result
		} catch {
			await volume.detach()
			throw error
		}
	}

	/// The 1 GiB non-zero image on this volume.
	func bigImage(named name: String = "tg-big.img") async throws -> String {
		let path = mountPoint + "/" + name
		try await TG.writeFile(path, size: Self.bigImageBytes, fill: 0x6B)
		return path
	}
}
