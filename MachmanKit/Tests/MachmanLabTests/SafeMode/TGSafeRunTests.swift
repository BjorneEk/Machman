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
				"tg-r1", disks: [data], policy: Self.safeHeadless, on: agent)
			let before = try await vm.info()
			let options = before.startOptions(.plain)
			#expect(options.safe && !options.openWindow)
			try await vm.start(options)
			// During: one run root, marked for this VM and its vmhost; the VM lists safe.
			let roots = TG.runRoots(agent.scope)
			try #require(roots.count == 1)
			let host = try await vm.hostPID()
			#expect(TG.marker(roots[0]) == TG.Marker(vm: "tg-r1", pid: host))
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
				"tg-r3", disks: [data], policy: Self.safeHeadless, on: agent)
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

	@Test("5: a safe run leaves an external image marked safe byte-for-byte unchanged")
	func safeExternalImageUnchanged() async throws {
		try await TG.withAgent { agent in
			let image = agent.scope.imagesDir + "/tg-ext.img"
			let mib = 32
			try await TG.writeFile(image, size: mib << 20)
			let before = try await TG.sha256(image)
			let vm = try await TGVM.alpine(
				"tg-r5", externals: [TGExternal(path: image)], policy: Self.safeHeadless,
				on: agent)
			let entry = try await vm.disk(path: image)
			#expect(entry.safe)
			#expect(entry.owned == false)
			try await vm.start(try await vm.info().startOptions(.plain))
			// The run root holds an owned clone of the image, not the image.
			let roots = TG.runRoots(agent.scope)
			try #require(roots.count == 1)
			let shadow = roots[0] + "/tg-r5"
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
