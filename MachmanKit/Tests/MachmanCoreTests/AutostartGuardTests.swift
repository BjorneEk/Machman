//
//  AutostartGuardTests.swift
//  MachmanTests
//
//  E38 (choice C8): the shared-disk and MAC guards ran only in the router's start, and a
//  VM that starts at login is booted by its own vmhost, which sees one VM. Two such VMs on
//  one writable image both booted at every login, corrupting it. Turning Start at login on
//  is refused beside such a VM now, read from the configs on disk.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct AutostartGuardTests {
	private let image = "/images/shared-\(UUID().uuidString).img"

	// alpha (Start at login off) and kept, written to the redirected library.
	@MainActor
	private func makePair(
		keptAutostart: Bool = true, alphaAutostart: Bool = false, mac: String? = nil,
		disk: VMDisk? = nil
	) throws {
		let shared = disk ?? VMDisk(kind: .fromUrl(URL(fileURLWithPath: image)))
		for (name, autostart) in [("alpha", alphaAutostart), ("kept", keptAutostart)] {
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			cfg.startPolicy = StartPolicy(windowed: true, safe: false, autostart: autostart)
			if let mac { cfg.macAddress = mac }
			try cfg.addDisk(disk: shared)
		}
	}

	@Test @MainActor func aSharedDiskRefusesStartAtLogin() throws {
		try VMTestDir.withRedirectedDir {
			try makePair()
			let refusal = try #require(
				BootGuard.autostartConflict(turningOn: "alpha", library: machmanVMDir))
			let file = (image as NSString).lastPathComponent
			#expect(refusal.code == .invalidState)
			#expect(refusal.message == "kept also starts at login with \(file) attached \u{2014} "
				+ "turn off Start at login for one of them")
		}
	}

	@Test @MainActor func aSharedMACRefusesStartAtLogin() throws {
		let mac = "aa:bb:cc:44:00:01"
		try VMTestDir.withRedirectedDir {
			try makePair(mac: mac, disk: VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/a.iso"))))
			let refusal = try #require(
				BootGuard.autostartConflict(turningOn: "alpha", library: machmanVMDir))
			#expect(refusal.message == "kept also starts at login with MAC address \(mac) "
				+ "\u{2014} regenerate the MAC address of one of them")
		}
	}

	@Test @MainActor func whatDoesntBootTogetherPasses() throws {
		try VMTestDir.withRedirectedDir {
			try makePair(keptAutostart: false)   // kept doesn't start at login
			#expect(BootGuard.autostartConflict(turningOn: "alpha", library: machmanVMDir) == nil)
		}
		try VMTestDir.withRedirectedDir {
			// An iso attaches read-only; the MACs differ.
			try makePair(disk: VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/a.iso"))))
			#expect(BootGuard.autostartConflict(turningOn: "alpha", library: machmanVMDir) == nil)
		}
		try VMTestDir.withRedirectedDir {
			// alpha starts at login already: editing its other run defaults isn't blocked.
			try makePair(alphaAutostart: true)
			#expect(BootGuard.autostartConflict(turningOn: "alpha", library: machmanVMDir) == nil)
		}
	}
}
