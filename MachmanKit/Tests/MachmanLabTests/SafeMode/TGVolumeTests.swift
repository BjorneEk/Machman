//
//  TGVolumeTests.swift
//  MachmanLabTests
//
//  L2 — a second volume (a sparse APFS image the test attaches, B-2): a safe run's shadow
//  build and an import that are real byte copies report determinate progress, and Save as
//  New VM refuses a library on another volume than its safe runs while the run goes on.
//

import Foundation
import Testing
import MachmanAPI
import MachmanUI

@Suite("Second volume", .serialized, .enabled(if: Lab.runs(.l2) && TGVolume.enabled))
struct TGVolumeTests {
	static let safeHeadless = StartPolicy(windowed: false, safe: true)

	/// A determinate copy: several events, one total of at least the image, never going
	/// back, and at least one mid-copy.
	static func expectDeterminate(_ progress: [TGEvents.Progress], _ what: String) {
		#expect(progress.count >= 3, "\(what)")
		let totals = Set(progress.map(\.total))
		#expect(totals.count == 1, "\(what)")
		#expect((totals.first ?? 0) >= UInt64(TGVolume.bigImageBytes), "\(what)")
		#expect(zip(progress, progress.dropFirst()).allSatisfy { $0.copied <= $1.copied },
			"\(what)")
		#expect(progress.contains { $0.copied > 0 && $0.copied < $0.total }, "\(what)")
	}

	static func finished(_ op: OperationInfo, kind: String, vm: String) -> Bool {
		op.kind == kind && op.vm == vm && op.isFinished
	}

	@Test("21: a cross-volume safe disk and a cross-volume import report determinate progress")
	func crossVolumeProgress() async throws {
		try await TGVolume.with(sizeGiB: 3) { volume in
			let big = try await volume.bigImage()
			try await TG.withAgent { agent in
				let vm = try await TGVM.alpine(
					"tg-r21", externals: [TGExternal(path: big)], policy: Self.safeHeadless,
					on: agent)
				let events = await TGEvents.record(agent.api)
				defer { events.stop() }
				// The shadow build clones the safe external image: a byte copy across volumes.
				var mark = events.mark()
				try await vm.start(try await vm.info().startOptions(.plain), timeout: .seconds(180))
				let build = OperationInfo.Kind.shadowBuild
				try await events.waitFor(after: mark) {
					guard case .operationChanged(let op) = $0 else { return false }
					return Self.finished(op, kind: build, vm: vm.name)
				}
				Self.expectDeterminate(events.copyProgress(vm: vm.name, after: mark), "safe run")
				let builds = events.operations(kind: build, vm: vm.name, after: mark)
				#expect(builds.allSatisfy { $0.label == "Preparing a safe run" })
				#expect(builds.contains { ($0.fraction ?? 0) > 0 && ($0.fraction ?? 1) < 1 })
				#expect(builds.last?.state == OperationInfo.State.succeeded)
				try await vm.forceStop()
				#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
				// The same image imported into the VM's folder: a byte copy too.
				mark = events.mark()
				let imported = try await agent.api.importDisk(vm: vm.name, path: big)
				let kind = OperationInfo.Kind.importDisk
				try await events.waitFor(after: mark) {
					guard case .operationChanged(let op) = $0 else { return false }
					return Self.finished(op, kind: kind, vm: vm.name)
				}
				Self.expectDeterminate(events.copyProgress(vm: vm.name, after: mark), "import")
				let imports = events.operations(kind: kind, vm: vm.name, after: mark)
				#expect(imports.contains { ($0.fraction ?? 0) > 0 && ($0.fraction ?? 1) < 1 })
				#expect(imports.last?.state == OperationInfo.State.succeeded)
				let disk = imported.disks.first { $0.type == .storage && $0.owned == true }
				#expect(disk?.sizeBytes == UInt64(TGVolume.bigImageBytes))
				#expect(disk?.path?.hasPrefix(vm.dir + "/") == true)
			}
		}
	}

	@Test("W2-39: Save as New VM is refused for a library on another volume; the run goes on")
	func saveRefusedAcrossVolumes() async throws {
		try await TGVolume.with(sizeGiB: 2) { volume in
			let library = volume.mountPoint + "/VMs"
			// The library on the second volume; the safe runs stay beside it on /tmp.
			let prepare: (LabScope) async throws -> Void = { scope in
				try FileManager.default.createDirectory(
					atPath: library, withIntermediateDirectories: true)
				try FileManager.default.createSymbolicLink(
					atPath: TG.vmsDir(scope), withDestinationPath: library)
			}
			try await TG.withAgent(prepare: prepare) { agent in
				let vm = try await TGVM.alpine("tg-w239", policy: Self.safeHeadless, on: agent)
				#expect(FileManager.default.fileExists(atPath: library + "/tg-w239/config"))
				try await vm.start(try await vm.info().startOptions(.plain))
				let guest = try await vm.guest()
				defer { guest.console.close() }
				let run = "run-" + TG.nonce()
				try await guest.set("TGWHO", run)
				let refused = await #expect(throws: MachmanError.self) {
					_ = try await agent.api.safeSave(vm: "tg-w239", to: "tg-w239-kept")
				}
				#expect(refused?.code == .invalidState)
				#expect(refused?.message
					== "Save as New VM needs the VM library on the same volume as its safe runs")
				// The run goes on, still safe, the same shell; no saved VM anywhere.
				let info = try await vm.info()
				#expect(info.state == .running)
				#expect(info.safeRun == true)
				#expect(try await guest.value(of: "TGWHO") == run)
				#expect(try await agent.api.listVMs().allSatisfy { $0.name != "tg-w239-kept" })
				#expect(!FileManager.default.fileExists(atPath: library + "/tg-w239-kept"))
				guest.console.close()
				try await vm.forceStop()
				#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			}
		}
	}
}
