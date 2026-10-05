//
//  EngineConfigEditTests.swift
//  MachmanLabTests
//
//  L2 — configs a person (or a newer Machman) edited by hand, as the engine meets them: a
//  boot mode from a newer build (D26), two mounts on one tag (D25), and a re-tagged active
//  kernel with its command-line override (D21). Every edit is made while no agent serves
//  the library (TFAgents.restartForEdit).
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient

@Suite("Engine — hand-edited configs", .serialized, .enabled(if: Lab.runs(.l2)))
struct EngineConfigEditTests {
	/// Draft card (r3-tf): vm.kernel.setOverride saves the override and VMInfo lists it, but
	/// makeBootLoader boots KernelSettings.commandLine; nothing reads kernelOverrides at start.
	static let overrideNeverBootsCard = Comment(rawValue: "A kernel’s command-line override "
		+ "is saved and listed but never reaches the boot")

	@Test(
		"""
		R3W2-3: a newer boot mode lists as Unknown, refuses Start and keeps its boot \
		through a CPU change
		""")
	func newerBootModeKept() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "d26", boot: .alpine()), start: false) { vm in
				let dir = TFVM.dir(agent, vm.name)
				let future: [String: Any] = ["futureMode": ["_0": ["x": 1]]]
				try await TFAgents.restartForEdit(agent) {
					try TFVM.editConfig(dir: dir) { $0["boot"] = future }
				}
				let before = try TFVM.canonicalJSON(try TFVM.readConfig(dir: dir)["boot"] as Any)
				#expect(before == (try TFVM.canonicalJSON(future)))
				let info = try await vm.info()
				#expect(info.boot.mode == .unknown)
				let mark = LabLog.mark()
				do {
					try await agent.api.start(vm: vm.name, options: StartOptions(openWindow: false))
					Issue.record("a start of a newer boot mode was accepted")
				} catch let error as MachmanError {
					#expect(error.message.hasPrefix(BootInfo.newerModeReason))
				}
				do {
					try await agent.api.setKernelBoot(vm: vm.name, enabled: true)
					Issue.record("a boot-mode change of a newer boot mode was accepted")
				} catch let error as MachmanError {
					#expect(error.message.hasPrefix(BootInfo.newerModeReason))
				}
				// No vmhost was launched for it (no Dock icon could flash).
				try await Task.sleep(for: .seconds(1))
				#expect(LabLog.count("test mode: vmhost for d26", after: mark) == 0)
				let socket = MachmanPaths.vmSocketPath(vm: "d26")
				#expect(!FileManager.default.fileExists(atPath: socket))
				try await agent.api.setHardware(
					vm: vm.name, cpuCount: 2, memoryBytes: nil, nestedVirtualization: nil)
				let after = try TFVM.readConfig(dir: dir)
				#expect(try TFVM.canonicalJSON(after["boot"] as Any) == before)
				#expect(after["cpuCount"] as? Int == 2)
				#expect(try await vm.info().boot.mode == .unknown)
			}
		}
	}

	@Test("R3W2-2: two mounts sharing a tag start with one warning and the guest sees the first")
	func doubledTagSharesTheFirst() async throws {
		try await Lab.withAgent { agent in
			let shares = agent.scope.dir + "/shares"
			for (dir, marker) in [("a", "A"), ("b", "B")] {
				try FileManager.default.createDirectory(
					atPath: shares + "/" + dir, withIntermediateDirectories: true)
				try marker.write(
					toFile: shares + "/\(dir)/marker", atomically: true, encoding: .utf8)
			}
			let spec = LabVMSpec(
				name: "d25", boot: .alpine(),
				mounts: [
					.init(path: shares + "/a", tag: "x"), .init(path: shares + "/b", tag: "y"),
				])
			try await agent.withVM(spec, start: false) { vm in
				let dir = TFVM.dir(agent, vm.name)
				try await TFAgents.restartForEdit(agent) {
					try TFVM.editConfig(dir: dir) { config in
						guard var mounts = config["mountPoints"] as? [[String: Any]],
							mounts.count == 2
						else { throw TFError.precondition("d25's config has no two mountPoints") }
						mounts[1]["tag"] = "x"
						config["mountPoints"] = mounts
					}
				}
				#expect(try await vm.info().mounts.map(\.tag) == ["x", "x"])
				let events = await TFEvents(api: agent.api)
				defer { events.stop() }
				try await vm.start()
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				let sentence = "Two mounts share the tag “x”, so only the first is shared."
				try await events.waitFor("the doubled-tag warning", timeout: .seconds(10)) {
					$0 == .log(vm: "d25", level: .warning, message: sentence)
				}
				try await TFGuest.mountShare(console)
				let seen = try await console.run("cat /mnt/s/x/marker")
				#expect(seen.status == 0)
				#expect(seen.output == "A")
				#expect(try await console.run("ls /mnt/s/y 2>/dev/null").output == "")
				let warned = events.logs(vm: "d25", level: .warning).filter { $0 == sentence }
				#expect(warned.count == 1)
			}
		}
	}

	@Test("R3W2-1: a re-tagged active kernel boots with its command-line override")
	func retaggedKernelBoots() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "d21", boot: .alpine()), start: false) { vm in
				let api = agent.api
				let current = try await vm.info().boot.kernel
				let kernelSource = try #require(current?.kernelPath)
				let initrdSource = try #require(current?.initrdPath)
				var info = try await api.promoteKernelFile(
					vm: vm.name, role: .kernel, sourcePath: kernelSource, tag: "a")
				info = try await api.promoteKernelFile(
					vm: vm.name, role: .initramfs, sourcePath: initrdSource, tag: "a")
				let owned = info.boot.ownedKernels ?? []
				let kernel = try #require(owned.first { $0.role == .kernel })
				let initrd = try #require(owned.first { $0.role == .initramfs })
				try await api.updateKernelSettings(
					vm: vm.name, KernelSettings(
						kernelPath: kernel.path, initrdPath: initrd.path,
						commandLine: LabVMSpec.alpineCommandLine))
				let line = LabVMSpec.alpineCommandLine + " lab.tf=r3w2-1"
				_ = try await api.setKernelOverride(
					vm: vm.name, path: kernel.path, commandLine: line, overrideEnabled: true)
				info = try await api.renameKernelFile(vm: vm.name, path: kernel.path, tag: "b")
				let moved = try #require(info.boot.ownedKernels?.first { $0.role == .kernel })
				#expect(moved.tag == "b")
				#expect(moved.path != kernel.path)
				#expect(info.boot.kernel?.kernelPath == moved.path)
				try await vm.start()
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				let cmdline = try await console.run("cat /proc/cmdline")
				#expect(cmdline.status == 0)
				withKnownIssue(Self.overrideNeverBootsCard) {
					#expect(cmdline.output.contains("lab.tf=r3w2-1"))
				}
				let after = try await vm.info().boot.ownedKernels?.first { $0.role == .kernel }
				#expect(after?.path == moved.path)
				#expect(after?.overrideCommandLine == line)
				#expect(after?.overrideEnabled == true)
			}
		}
	}
}
