//
//  THPayloadImage.swift
//  MachmanLabTests
//
//  A carrier VM's payload as a disk image, for guests that can reach neither the share nor the
//  lab sshd at boot (the vzfreebsd image under VZ, the OpenBSD/NetBSD spikes): GuestSetup and
//  GuestReport copied into an ISO9660/Joliet image by hdiutil makehybrid — never hdiutil
//  attach, so no volume is mounted on the Mac (no Finder, no Spotlight). The guest mounts it
//  read-only (mount_cd9660) and copies it to /mnt/machman/share.
//

import Foundation
import MachmanAPI
import MachmanTestSupport

enum THPayloadImage {
	/// <run>/th/<scope>/payload.img holding `carrier`'s GuestSetup and GuestReport.
	static func make(from carrier: THVM) async throws -> String {
		let dir = try TH.hostDir(carrier.agent, "payload")
		let stage = dir + "/stage"
		let manager = FileManager.default
		try? manager.removeItem(atPath: stage)
		try manager.createDirectory(atPath: stage, withIntermediateDirectories: true)
		for name in [GuestSetupInstallerInfo.directoryName,
			GuestSetupInstallerInfo.reportDirectoryName] {
			let source = carrier.shareDir + "/" + name
			guard manager.fileExists(atPath: source) else {
				throw LabError.specInvalid("\(carrier.name) serves no \(name) yet")
			}
			try manager.copyItem(atPath: source, toPath: stage + "/" + name)
		}
		let iso = dir + "/payload.iso"
		try? manager.removeItem(atPath: iso)
		let made = try await Subprocess.run(
			"/usr/bin/hdiutil",
			["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "MACHMAN",
				"-o", iso, stage],
			environment: ["PATH": "/usr/bin:/bin"], timeout: 120)
		guard made.status == 0, manager.fileExists(atPath: iso) else {
			throw LabError.commandFailed(
				command: "hdiutil makehybrid \(iso)", status: made.status, output: made.output)
		}
		// A raw disk to the guest (virtio): the .img name keeps it off the ISO (USB) path.
		let image = dir + "/payload.img"
		try? manager.removeItem(atPath: image)
		try manager.moveItem(atPath: iso, toPath: image)
		try? manager.removeItem(atPath: stage)
		return image
	}

	/// The guest-side lines (root) that copy the payload disk at `device` to the share path.
	static func install(device: String, mountpoint: String = "/mnt/th-payload") -> [String] {
		[
			"mkdir -p \(mountpoint) \(GuestPaths.share)",
			"mount -t cd9660 -o ro \(device) \(mountpoint)",
			"cp -R \(mountpoint)/\(GuestSetupInstallerInfo.directoryName)"
				+ " \(mountpoint)/\(GuestSetupInstallerInfo.reportDirectoryName)"
				+ " \(GuestPaths.share)/",
			"umount \(mountpoint)",
		]
	}
}

/// The vzfreebsd image under VZ (runs only when the lab cache holds it): a carrier VM serves the
/// payload, which reaches the guest as a disk image, since FreeBSD has no virtiofs driver.
enum THVZFreeBSD {
	final class Guest: @unchecked Sendable {
		let vm: THVM
		let driver: LabConsole

		init(vm: THVM, driver: LabConsole) {
			self.vm = vm
			self.driver = driver
		}

		func sh(_ command: String) async throws -> (status: Int32, output: String) {
			try await THConsoleSession.run(driver, command, timeout: .seconds(300))
		}

		@discardableResult
		func check(_ command: String) async throws -> String {
			let result = try await sh(command)
			guard result.status == 0 else {
				throw LabError.commandFailed(
					command: command, status: result.status, output: result.output)
			}
			return result.output
		}
	}

	/// `body` with root logged in on console 0 and the payload copied to the share path.
	static func withGuest(_ body: (Guest, String) async throws -> Void) async throws {
		try await Lab.withAgent { agent in
			let carrier = try await THVM.create(
				LabVMSpec(
					name: "payload carrier", boot: .alpine(), consolePorts: 2,
					devices: [.guestSetup]),
				on: agent)
			var vm: THVM?
			do {
				try await carrier.start()
				let payload = try await THPayloadImage.make(from: carrier)
				let image = VZFreeBSD.imagePath
				let guestVM = try await THVM.create(
					LabVMSpec(
						name: "vzfreebsd", boot: .efiImagePath(image), cpus: 2, memoryGiB: 2,
						consolePorts: 2, extraDisks: [payload]),
					on: agent)
				vm = guestVM
				let driver = try await guestVM.bootLoggedIn(0, label: "ttyV0")
				defer { driver.close() }
				let guest = Guest(vm: guestVM, driver: driver)
				let disk = try await guest.check(
					"for d in /dev/vtbd[1-9]; do dd if=$d bs=2048 skip=16 count=1 2>/dev/null"
						+ " | grep -q CD001 && echo $d; done | head -n 1")
				for line in THPayloadImage.install(device: disk) { try await guest.check(line) }
				try await body(guest, GuestPaths.share)
				await guestVM.cleanup()
				await carrier.cleanup()
			} catch {
				await vm?.cleanup()
				await carrier.cleanup()
				throw error
			}
		}
	}
}
