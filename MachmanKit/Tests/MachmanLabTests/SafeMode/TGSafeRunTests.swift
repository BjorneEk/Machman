//
//  TGSafeRunTests.swift
//  MachmanLabTests
//
//  L2 — safe runs on the Alpine fixture: what a safe run's guest writes goes with its run
//  dir unless the disk is marked unsafe, an external image marked safe stays byte-for-byte,
//  and the session's history still reaches the real VM.
//

import Foundation
import Testing
import MachmanAPI
import MachmanUI

@Suite("Safe runs", .serialized, .enabled(if: Lab.runs(.l2)))
struct TGSafeRunTests {
	static let safeHeadless = StartPolicy(windowed: false, safe: true)

	@Test("1: a safe run's disk writes go with its run dir, and its runtime is copied back")
	func safeRunDiscardsWrites() async throws {
		try await TG.withAgent { agent in
			let data = TGDisk(name: "data", mib: 64)
			let vm = try await TGVM.alpine(
				"safe-writes", disks: [data], policy: Self.safeHeadless, on: agent)
			let before = try await vm.info()
			let options = before.startOptions(.plain)
			#expect(options.safe && !options.openWindow)
			try await vm.start(options)
			// During: one run root, marked for this VM and its vmhost; the VM lists safe.
			let roots = TG.runRoots(agent.scope)
			try #require(roots.count == 1)
			let host = try await vm.hostPID()
			#expect(TG.marker(roots[0]) == TG.Marker(vm: "safe-writes", pid: host))
			#expect(try await vm.info().safeRun == true)
			let marker = "TG1-" + TG.nonce()
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				#expect(try await guest.loadBlockDriver(count: 1) == 1)
				let device = try await guest.device(sectors: data.sectors)
				try await guest.writeMarker(marker, device: device, sector: 8)
				#expect(try await guest.readMarker(
					device: device, sector: 8, length: marker.count) == marker)
			}
			try await Task.sleep(for: .seconds(2))
			try await vm.forceStop()
			// After: the run dir is gone, the real disk never saw the write…
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			#expect(!FileManager.default.fileExists(atPath: roots[0]))
			let real = vm.dir + "/data.raw"
			#expect(try TG.bytes(real, offset: 4096, count: marker.count) != Data(marker.utf8))
			// …and the session's history is the real VM's now.
			let after = try await vm.info()
			let lastRan = try #require(after.lastRan)
			#expect(lastRan > (before.lastRan ?? .distantPast))
			#expect((after.totalRuntimeSeconds ?? 0) >= (before.totalRuntimeSeconds ?? 0) + 1)
			// An unsafe run of the same VM reads no marker.
			try await vm.start(StartOptions(openWindow: false))
			#expect(try await vm.info().safeRun != true)
			#expect(TG.runRoots(agent.scope).isEmpty)
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				try await guest.loadBlockDriver(count: 1)
				let device = try await guest.device(sectors: data.sectors)
				#expect(try await guest.readMarker(
					device: device, sector: 8, length: marker.count) != marker)
			}
			try await vm.forceStop()
		}
	}

	@Test("3: a disk marked unsafe keeps what a safe run wrote")
	func unsafeDiskKeepsWrites() async throws {
		try await TG.withAgent { agent in
			let data = TGDisk(name: "data", mib: 64, safe: false)
			let vm = try await TGVM.alpine(
				"unsafe-disk", disks: [data], policy: Self.safeHeadless, on: agent)
			#expect(try await vm.disk(named: "data").safe == false)
			try await vm.start(try await vm.info().startOptions(.plain))
			#expect(try await vm.info().safeRun == true)
			let marker = "TG3-" + TG.nonce()
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				try await guest.loadBlockDriver(count: 1)
				let device = try await guest.device(sectors: data.sectors)
				try await guest.writeMarker(marker, device: device, sector: 8)
			}
			try await vm.forceStop()
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			// The run wrote the real file, and an unsafe run reads it there.
			#expect(await TG.waitForBytes(vm.dir + "/data.raw", offset: 4096, marker))
			try await vm.start(StartOptions(openWindow: false))
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				try await guest.loadBlockDriver(count: 1)
				let device = try await guest.device(sectors: data.sectors)
				#expect(try await guest.readMarker(
					device: device, sector: 8, length: marker.count) == marker)
			}
			try await vm.forceStop()
		}
	}

	@Test("4: a safe run shares only the unsafe mount; a plain run shares both")
	func safeRunSharesUnsafeMountOnly() async throws {
		try await TG.withAgent { agent in
			let shares = agent.scope.dir + "/shares"
			for name in ["a", "b"] {
				try FileManager.default.createDirectory(
					atPath: shares + "/" + name, withIntermediateDirectories: true)
				try Data("tg \(name)\n".utf8)
					.write(to: URL(fileURLWithPath: shares + "/\(name)/hello.txt"))
			}
			let vm = try await TGVM.alpine(
				"safe-mounts",
				mounts: [
					TGMount(path: shares + "/a", tag: "tga"),
					TGMount(path: shares + "/b", tag: "tgb", safe: false),
				],
				policy: Self.safeHeadless, on: agent)
			let mounts = try await vm.info().mounts
			#expect(mounts.first { $0.tag == "tga" }?.safe == true)
			#expect(mounts.first { $0.tag == "tgb" }?.safe == false)
			try await vm.start(try await vm.info().startOptions(.plain))
			#expect(try await vm.info().safeRun == true)
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				#expect(try await guest.shareTags() == ["tgb"])
				#expect(try await guest.run("cat /mnt/s/tgb/hello.txt") == "tg b")
			}
			try await vm.forceStop()
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			try await vm.start(StartOptions(openWindow: false))
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				#expect(try await guest.shareTags() == ["tga", "tgb"])
			}
			try await vm.forceStop()
		}
	}

	@Test("13: run defaults are refused during a safe run; a disk shield flip reverts after it")
	func runDefaultsRefusedShieldReverts() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine(
				"safe-defaults", disks: [TGDisk(name: "data", mib: 64)], policy: Self.safeHeadless,
				on: agent)
			let id = try await vm.disk(named: "data").id
			try await vm.start(try await vm.info().startOptions(.plain))
			#expect(try await vm.info().safeRun == true)
			let refusal = await #expect(throws: MachmanError.self) {
				try await vm.api.setStartPolicy(
					vm: "safe-defaults", policy: StartPolicy(windowed: true, safe: true))
			}
			#expect(refusal?.code == .invalidState)
			#expect(refusal?.message
				== "Run defaults can\u{2019}t change during a safe run \u{2014} stop safe-defaults "
					+ "or save it first")
			// The shield flip goes to the run's own (discardable) config.
			try await vm.api.setSafety(vm: "safe-defaults", disks: [id: false], mounts: nil)
			#expect(try await vm.disk(named: "data").safe == false)
			#expect(try await vm.info().startPolicy == Self.safeHeadless)
			try await vm.forceStop()
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			#expect(try await vm.disk(named: "data").safe == true)
			let disks = try TG.config(agent.scope, "safe-defaults")["disks"] as? [[String: Any]]
			#expect(disks?.count == 1)
			#expect(disks?.first?["safe"] as? Bool == true)
		}
	}

	@Test("5: a safe run leaves an external image marked safe byte-for-byte unchanged")
	func safeExternalImageUnchanged() async throws {
		try await TG.withAgent { agent in
			let image = agent.scope.imagesDir + "/tg-ext.img"
			let mib = 32
			try await TG.writeFile(image, size: mib << 20)
			let before = try await TG.sha256(image)
			let vm = try await TGVM.alpine(
				"safe-external", externals: [TGExternal(path: image)], policy: Self.safeHeadless,
				on: agent)
			let entry = try await vm.disk(path: image)
			#expect(entry.safe)
			#expect(entry.owned == false)
			try await vm.start(try await vm.info().startOptions(.plain))
			// The run root holds an owned clone of the image, not the image.
			let roots = TG.runRoots(agent.scope)
			try #require(roots.count == 1)
			let shadow = roots[0] + "/safe-external"
			let raws = ((try? FileManager.default.contentsOfDirectory(atPath: shadow)) ?? [])
				.filter { $0.hasSuffix(".raw") }
			let sizes = raws.compactMap {
				(try? FileManager.default.attributesOfItem(atPath: shadow + "/" + $0))?[.size]
					as? NSNumber
			}.map(\.intValue)
			#expect(sizes.contains(mib << 20))
			let marker = "TG5-" + TG.nonce()
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				try await guest.loadBlockDriver(count: 1)
				let device = try await guest.device(sectors: mib * 2048)
				try await guest.writeMarker(marker, device: device, sector: 8)
			}
			try await vm.forceStop()
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			#expect(try await TG.sha256(image) == before)
		}
	}
}
