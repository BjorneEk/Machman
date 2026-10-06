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
	// A login boot that answers at once when a sharer holds a lock.
	static let noWait = BootGuard.LoginWait(polls: 0, pause: {})

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

	// The login half: the vmhost about to boot alpha finds kept's vmhost answering, and kept
	// shares its image. Read-only — a config the loader would migrate is left as it is.
	@Test @MainActor func aLoginStartSeesARunningSharer() throws {
		try VMTestDir.withRedirectedDir {
			try makePair(keptAutostart: false)
			let keptConfig = machmanVMDir + "/kept/config"
			var json = try #require(try JSONSerialization.jsonObject(
				with: Data(contentsOf: URL(fileURLWithPath: keptConfig))) as? [String: Any])
			json["macAddress"] = nil   // VMConfig.load would mint one and save it
			try JSONSerialization.data(withJSONObject: json)
				.write(to: URL(fileURLWithPath: keptConfig))
			let before = try Data(contentsOf: URL(fileURLWithPath: keptConfig))
			let runtime = "/run/mm"
			let keptSocket = MachmanPaths.vmSocketPath(vm: "kept", runtimeDir: runtime)

			let refusal = try #require(BootGuard.runningSharerConflict(
				vm: "alpha", library: machmanVMDir, runtimeDir: runtime,
				isLive: { $0 == keptSocket }))
			let file = (image as NSString).lastPathComponent
			#expect(refusal.message
				== "kept may still have \(file) attached \u{2014} stop kept before starting alpha")
			#expect(BootGuard.runningSharerConflict(
				vm: "alpha", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }) == nil)   // kept doesn't run
			#expect(try Data(contentsOf: URL(fileURLWithPath: keptConfig)) == before)
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

	// E54: two login vmhosts launched together each bound their socket before looking for
	// the other's, saw it and both refused. A login boot is decided by a lock per writable
	// disk file and per MAC now, taken before the vmhost binds: exactly one boots, and holds
	// its locks for the run.
	@Test("E54: of two login sharers deciding together, exactly one may boot")
	@MainActor func ofTwoLoginSharersExactlyOneMayBoot() throws {
		let runtime = TestEnvironment.socketPath("mm-login", suffix: "")
		try VMTestDir.withRedirectedDir {
			try makePair(alphaAutostart: true)
			let file = (image as NSString).lastPathComponent
			let first = try BootGuard.claimLoginBoot(
				vm: "alpha", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: Self.noWait).get()
			let second = BootGuard.claimLoginBoot(
				vm: "kept", library: machmanVMDir, runtimeDir: runtime, isLive: { _ in false },
				wait: Self.noWait)
			guard case .failure(let refusal) = second else {
				Issue.record("both login sharers may boot on one writable image")
				return
			}
			#expect(refusal.message == "alpha is running with \(file) attached \u{2014} "
				+ "stop alpha before starting kept")
			first.release()
			let afterwards = try BootGuard.claimLoginBoot(
				vm: "kept", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: Self.noWait).get()
			afterwards.release()
		}
	}

	@Test("E54: login sharers of one MAC take turns too")
	@MainActor func loginSharersOfOneMACTakeTurns() throws {
		let runtime = TestEnvironment.socketPath("mm-login", suffix: "")
		let mac = "aa:bb:cc:44:00:02"
		try VMTestDir.withRedirectedDir {
			try makePair(
				alphaAutostart: true, mac: mac,
				disk: VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/a.iso"))))
			let first = try BootGuard.claimLoginBoot(
				vm: "alpha", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: Self.noWait).get()
			defer { first.release() }
			let second = BootGuard.claimLoginBoot(
				vm: "kept", library: machmanVMDir, runtimeDir: runtime, isLive: { _ in false },
				wait: Self.noWait)
			guard case .failure(let refusal) = second else {
				Issue.record("both login sharers of one MAC may boot")
				return
			}
			#expect(refusal.message == "kept and the running VM \u{201C}alpha\u{201D} share MAC "
				+ "address \(mac), so one of them would lose networking")
		}
	}

	// What shares nothing boots side by side; a sharer the agent started (its socket answers,
	// it takes no lock) still stops a login boot.
	@Test("E54: login VMs that share nothing both boot, and a running sharer still refuses one")
	@MainActor func loginVMsThatShareNothingBothBoot() throws {
		let runtime = TestEnvironment.socketPath("mm-login", suffix: "")
		try VMTestDir.withRedirectedDir {
			try makePair(
				alphaAutostart: true, disk: VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/a.iso"))))
			let first = try BootGuard.claimLoginBoot(
				vm: "alpha", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: Self.noWait).get()
			let second = try BootGuard.claimLoginBoot(
				vm: "kept", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: Self.noWait).get()
			first.release()
			second.release()
		}
		try VMTestDir.withRedirectedDir {
			try makePair(keptAutostart: false)
			let keptSocket = MachmanPaths.vmSocketPath(vm: "kept", runtimeDir: runtime)
			let claim = BootGuard.claimLoginBoot(
				vm: "alpha", library: machmanVMDir, runtimeDir: runtime,
				isLive: { $0 == keptSocket }, wait: Self.noWait)
			guard case .failure(let refusal) = claim else {
				Issue.record("a login boot beside a running sharer")
				return
			}
			#expect(refusal.message.hasPrefix("kept may still have "))
		}
	}

	// Review F2 (wave r3w3): a lost login lock refused at once, so a winner that then failed
	// its start (or refused on another resource) left neither VM booting. A login boot waits
	// for the lock, bounded: a holder that gives up frees it and the waiter boots…
	@Test("E54: a login boot waits for a sharer's lock and boots once the sharer gives up")
	@MainActor func aLoginBootWaitsForASharerThatGivesUp() throws {
		let runtime = TestEnvironment.socketPath("mm-login", suffix: "")
		try VMTestDir.withRedirectedDir {
			try makePair(alphaAutostart: true)
			let first = try BootGuard.claimLoginBoot(
				vm: "alpha", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: Self.noWait).get()
			var pauses = 0
			let wait = BootGuard.LoginWait(polls: 10) {
				pauses += 1
				first.release()   // alpha's start failed: its vmhost exits
			}
			let second = try BootGuard.claimLoginBoot(
				vm: "kept", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: wait).get()
			#expect(pauses == 1)
			second.release()
		}
	}

	// …and a holder that booted keeps it: the waiter refuses with today's sentence, at once
	// (the holder marked its lock) or at the bound (it still hadn't decided).
	@Test("E54: a login boot refuses beside a sharer that booted, or still decides at the bound")
	@MainActor func aLoginBootRefusesBesideABootedSharer() throws {
		let runtime = TestEnvironment.socketPath("mm-login", suffix: "")
		try VMTestDir.withRedirectedDir {
			try makePair(alphaAutostart: true)
			let file = (image as NSString).lastPathComponent
			let sentence = "alpha is running with \(file) attached \u{2014} "
				+ "stop alpha before starting kept"
			let first = try BootGuard.claimLoginBoot(
				vm: "alpha", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: Self.noWait).get()
			defer { first.release() }
			var pauses = 0
			let wait = BootGuard.LoginWait(polls: 3) { pauses += 1 }
			let undecided = BootGuard.claimLoginBoot(
				vm: "kept", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: wait)
			guard case .failure(let atTheBound) = undecided else {
				Issue.record("kept took a lock alpha holds")
				return
			}
			#expect(pauses == 3)
			#expect(atTheBound.message == sentence)
			first.markBooted()
			pauses = 0
			let booted = BootGuard.claimLoginBoot(
				vm: "kept", library: machmanVMDir, runtimeDir: runtime,
				isLive: { _ in false }, wait: wait)
			guard case .failure(let atOnce) = booted else {
				Issue.record("kept took a lock alpha holds")
				return
			}
			#expect(pauses == 0)
			#expect(atOnce.message == sentence)
		}
	}
}
