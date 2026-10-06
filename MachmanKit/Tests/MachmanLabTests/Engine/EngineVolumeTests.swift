//
//  EngineVolumeTests.swift
//  MachmanLabTests
//
//  L2 — a library on a second volume that has no clonefile (C6): exFAT and HFS+ disk images
//  under the run root (TFVolume). Duplicating a kernel-boot VM byte-copies its owned kernel
//  files and the copy boots them; an import from the APFS volume crosses volumes. Second
//  volumes are on by default (B-2); MACHMAN_LAB_VOLUMES=0 skips the suite.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient

@Suite(
	"Engine — second volumes", .serialized,
	.enabled(if: Lab.runs(.l2) && TFGate.volumes, TFGate.volumesReason))
struct EngineVolumeTests {
	@Test(
		"""
		W2-32: a library on a non-APFS volume duplicates a kernel VM and imports across \
		volumes
		""",
		arguments: [TFVolume.Format.exfat, .hfsPlus])
	func nonAPFSLibrary(_ format: TFVolume.Format) async throws {
		let name = format == .exfat ? "lab-exfat" : "lab-hfs"
		try await TFVolume.with(format, gib: 2, name: name) { volume in
			let data = volume.mountPoint + "/data"
			try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
			let options = LabAgent.Options(environment: ["MACHMAN_DATA_DIR": data])
			try await Lab.withAgent(options) { agent in
				let api = agent.api
				let vm = try await LabVM.create(
					LabVMSpec(name: "kernel-vm", boot: .alpine()), on: agent)
				let boot = try #require(try await vm.info().boot.kernel)
				_ = try await api.promoteKernelFile(
					vm: "kernel-vm", role: .kernel, sourcePath: boot.kernelPath, tag: "lab")
				let promoted = try await api.promoteKernelFile(
					vm: "kernel-vm", role: .initramfs, sourcePath: try #require(boot.initrdPath),
					tag: "lab")
				let owned = promoted.boot.ownedKernels ?? []
				let kernel = try #require(owned.first { $0.role == .kernel })
				let initrd = try #require(owned.first { $0.role == .initramfs })
				try await api.updateKernelSettings(
					vm: "kernel-vm", KernelSettings(
						kernelPath: kernel.path, initrdPath: initrd.path,
						commandLine: LabVMSpec.alpineCommandLine))
				#expect(kernel.path.hasPrefix(data + "/VMs/kernel-vm/"))
				let copy = try await api.copyVM(
					vm: "kernel-vm", newName: "kernel-vm copy", diskIDs: nil, mountIDs: nil,
					regenerateMAC: true)
				let copyDir = data + "/VMs/kernel-vm copy/"
				#expect(copy.boot.kernel?.kernelPath.hasPrefix(copyDir) == true)
				#expect(copy.boot.kernel?.initrdPath?.hasPrefix(copyDir) == true)
				try await TFVM.start(agent, "kernel-vm copy")
				let host = try await TFVM.peer("kernel-vm copy")
				let path = try #require(
					try await api.vm(named: "kernel-vm copy").consolePorts?.first?.socketPath)
				let console = try await LabConsole.connect(
					path, transcript: "\(agent.scope.id)-kernel-vm-copy")
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				// An import from the APFS volume into the library's volume.
				let raw = agent.scope.imagesDir + "/kernel-vm-import.raw"
				try await TFFiles.filled(raw, bytes: 64 << 20)
				let imported = try await api.importDisk(vm: "kernel-vm", path: raw)
				#expect(imported.disks.contains {
					$0.path?.hasPrefix(data + "/VMs/kernel-vm/") == true
				})
				#expect(LabProcesses.isAlive(agent.pid))
				#expect(LabProcesses.isAlive(host))
				await TFVM.forceStop(agent, "kernel-vm copy")
			}
		}
	}
}
