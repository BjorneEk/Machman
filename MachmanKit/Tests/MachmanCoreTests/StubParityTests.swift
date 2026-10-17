//
//  StubParityTests.swift
//  MachmanCoreTests
//
//  StubMachman against the engine (Q29): the view-model tests drive the stub, so where the
//  stub's mutators disagree with what the daemon serves, a desktop bug that lives in that
//  state can't be reproduced headless (review 4 found the stuck kernel sections that way).
//  Each case runs the same steps on a real VMConfig and on the stub and compares what both
//  serve: the boot, the disks, the mounts and the kernel files.
//

import Foundation
import Testing
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

// L1: unit (engine config in a redirected library, the stub in memory).
@MainActor
struct StubParityTests {
	struct Served: Equatable, CustomStringConvertible {
		let mode: BootInfo.Mode
		let kernel: KernelSettings?
		init(_ boot: BootInfo) {
			mode = boot.mode
			kernel = boot.kernel
		}
		var description: String { "\(mode) \(kernel.map { "\($0)" } ?? "no draft")" }
	}

	@Test("Q29: the stub's kernel-boot switch serves what the engine serves")
	func kernelBootSwitch() async throws {
		let steps = [true, false, true, false]
		var engine: [Served] = []
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			for enabled in steps {
				try vm.config.setKernelBoot(enabled: enabled)
				engine.append(Served(api.info(for: vm).boot))
			}
		}
		let stub = StubMachman.serving([StubMachman.makeInfo("Parity")])
		var served: [Served] = []
		for enabled in steps {
			try await stub.setKernelBoot(vm: "Parity", enabled: enabled)
			served.append(Served(try await stub.vm(named: "Parity").boot))
		}
		#expect(served == engine)
	}

	// N3: a parked draft emptied by a settings write goes; one that keeps a command line stays.
	@Test("Q29: an emptied parked draft goes on the stub as on the engine")
	func emptiedParkedDraft() async throws {
		let line = KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "quiet")
		let empty = KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		enum Step { case boot(Bool), write(KernelSettings) }
		let steps: [Step] = [.boot(true), .write(line), .boot(false), .write(empty)]
		var engine: [Served] = []
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			for step in steps {
				switch step {
				case .boot(let enabled):
					try vm.config.setKernelBoot(enabled: enabled)
				case .write(let settings):
					try vm.config.updateKernelSettings(LinuxKernelBoot(
						kernelPath: settings.kernelPath, initialRamdiskPath: settings.initrdPath,
						commandLine: settings.commandLine))
				}
				engine.append(Served(api.info(for: vm).boot))
			}
		}
		let stub = StubMachman.serving([StubMachman.makeInfo("Parity")])
		var served: [Served] = []
		for step in steps {
			switch step {
			case .boot(let enabled): try await stub.setKernelBoot(vm: "Parity", enabled: enabled)
			case .write(let settings): try await stub.updateKernelSettings(vm: "Parity", settings)
			}
			served.append(Served(try await stub.vm(named: "Parity").boot))
		}
		#expect(served == engine)
		#expect(served.last?.kernel == nil)
	}

	@Test("Q29: the stub's kernel delete clears the field that named the file, like the engine")
	func kernelDeleteClearsTheReference() async throws {
		var engine: Served?
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			let kernelsDir = vm.config.kernelsDirPath()
			let path = kernelsDir + "/kernel/v1/vmlinuz"
			try FileManager.default.createDirectory(
				atPath: kernelsDir + "/kernel/v1", withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: path))
			try vm.config.setKernelBoot(enabled: true)
			try vm.config.updateKernelSettings(LinuxKernelBoot(
				kernelPath: path, initialRamdiskPath: nil, commandLine: "console=hvc0"))
			// LocalMachman.deleteKernelFile's config steps, synchronously.
			try KernelStore.delete(path: path, kernelsDir: kernelsDir)
			try vm.config.clearKernelReference(to: path)
			engine = Served(api.info(for: vm).boot)
		}
		let path = "/vm/Parity/kernels/kernel/v1/vmlinuz"
		var info = StubMachman.makeInfo("Parity")
		info.boot = BootInfo(
			mode: .linuxKernel,
			kernel: KernelSettings(kernelPath: path, initrdPath: nil, commandLine: "console=hvc0"),
			macInstallState: nil, minCPUCount: nil, minMemoryBytes: nil,
			ownedKernels: [OwnedKernelFile(role: .kernel, tag: "v1", fileName: "vmlinuz",
				path: path)])
		let stub = StubMachman.serving([info])
		let after = try await stub.deleteKernelFile(vm: "Parity", path: path)
		#expect(Served(after.boot) == engine)
	}

	// H54: the draft and the kernel files go, the boot mode stays.
	@Test("Q29: the stub's kernel clear serves what the engine serves")
	func kernelClear() async throws {
		var engine: (served: Served, files: Int)?
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			let kernelsDir = vm.config.kernelsDirPath()
			let path = kernelsDir + "/kernel/v1/vmlinuz"
			try FileManager.default.createDirectory(
				atPath: kernelsDir + "/kernel/v1", withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: path))
			try vm.config.setKernelBoot(enabled: true)
			try vm.config.updateKernelSettings(LinuxKernelBoot(
				kernelPath: path, initialRamdiskPath: nil, commandLine: "console=hvc0"))
			try vm.config.setKernelBoot(enabled: false)
			// LocalMachman.clearKernelSettings' config step, synchronously.
			try vm.config.clearKernelSettings()
			let boot = api.info(for: vm).boot
			engine = (Served(boot), boot.ownedKernels?.count ?? 0)
		}
		let path = "/vm/Parity/kernels/kernel/v1/vmlinuz"
		var info = StubMachman.makeInfo("Parity")
		info.boot = BootInfo(
			mode: .efi,
			kernel: KernelSettings(kernelPath: path, initrdPath: nil, commandLine: "console=hvc0"),
			macInstallState: nil, minCPUCount: nil, minMemoryBytes: nil,
			ownedKernels: [OwnedKernelFile(role: .kernel, tag: "v1", fileName: "vmlinuz",
				path: path)])
		let stub = StubMachman.serving([info])
		let after = try await stub.clearKernelSettings(vm: "Parity")
		#expect(Served(after.boot) == engine?.served)
		#expect((after.boot.ownedKernels?.count ?? 0) == engine?.files)
		#expect(engine?.served.kernel == nil)
	}

	// A disk as both serve it, past what only the engine can know (its library paths, sizes).
	struct ServedDisk: Equatable, CustomStringConvertible {
		let id: String
		let type: DiskType
		let name: String?
		let owned: Bool?
		init(_ disk: DiskInfo) {
			id = disk.id
			type = disk.type
			name = disk.name
			owned = disk.owned
		}
		var description: String { id }
	}

	@Test("Q29: the stub's disk add and remove serve what the engine serves")
	func diskAddAndRemove() async throws {
		let dir = TestEnvironment.scratch + "parity-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let image = dir + "/extra.img"
		let iso = dir + "/install.iso"
		try Data(count: 1024).write(to: URL(fileURLWithPath: image))
		try Data(count: 1024).write(to: URL(fileURLWithPath: iso))
		enum Step { case add(NewDisk), remove(String) }
		let steps: [Step] = [
			.add(.storage(name: "data", sizeBytes: 1 << 20)), .add(.image(path: image)),
			.add(.iso(path: iso)), .add(.storage(name: "data", sizeBytes: 1 << 20)),
			.add(.image(path: image)), .remove("storage:data"),
			.remove("url:" + URL(fileURLWithPath: image).absoluteString),
		]
		var start: VMInfo?
		var engine: [[ServedDisk]] = []
		var engineRefused: [Bool] = []
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			start = api.info(for: vm)
			for step in steps {
				// LocalMachman.addDisk's and removeDisk's config steps, synchronously.
				do {
					switch step {
					case .add(let disk) where disk.type == .storage:
						try vm.config.addNewStorageDisk(
							name: disk.name ?? "", size: disk.sizeBytes ?? 0)
					case .add(let disk) where disk.type == .iso:
						try vm.config.addIsoDisk(isoUrl: URL(fileURLWithPath: disk.path ?? ""))
					case .add(let disk):
						try vm.config.addDisk(
							disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: disk.path ?? ""))))
					case .remove(let id):
						let disk = try #require(vm.config.disks.first { $0.id == id })
						try registry.removeDisk(disk, from: vm)
					}
					engineRefused.append(false)
				} catch is MachmanError {
					engineRefused.append(true)
				}
				engine.append(api.info(for: vm).disks.map(ServedDisk.init))
			}
		}
		let first = try #require(start)
		let stub = StubMachman.serving([first])
		var served: [[ServedDisk]] = []
		var stubRefused: [Bool] = []
		for step in steps {
			do {
				switch step {
				case .add(let disk): try await stub.addDisk(vm: first.name, disk)
				case .remove(let id): try await stub.removeDisk(vm: first.name, diskID: id)
				}
				stubRefused.append(false)
			} catch is MachmanError {
				stubRefused.append(true)
			}
			served.append(try await stub.vm(named: first.name).disks.map(ServedDisk.init))
		}
		#expect(served == engine)
		#expect(stubRefused == engineRefused)
		#expect(engineRefused == [false, false, false, true, true, false, false])
		// A disk already gone answers notFound, as LocalMachman.removeDisk does.
		let gone = try await #require(throws: MachmanError.self) {
			try await stub.removeDisk(vm: first.name, diskID: "storage:data")
		}
		#expect(gone.code == .notFound)
	}

	@Test("Q29: the stub's mount remove serves what the engine serves")
	func mountAddAndRemove() async throws {
		let paths = ["/Users/demo/src", "/Users/demo/data"]
		var start: VMInfo?
		var engine: [[String]] = []
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			start = api.info(for: vm)
			// LocalMachman.addMount's and removeMount's config steps.
			for path in paths {
				try vm.config.addMountPoint(HostMountPoint(
					path: path, tag: (path as NSString).lastPathComponent,
					kind: MountKind.virtiofs))
				engine.append(api.info(for: vm).mounts.map(\.tag))
			}
			let src = try #require(vm.config.mountPoints.first { $0.tag == "src" })
			try vm.config.removeMountPoint(src)
			engine.append(api.info(for: vm).mounts.map(\.tag))
		}
		let first = try #require(start)
		let stub = StubMachman.serving([first])
		var served: [[String]] = []
		for path in paths {
			try await stub.addMount(
				vm: first.name, path: path, tag: (path as NSString).lastPathComponent, kind: nil)
			served.append(try await stub.vm(named: first.name).mounts.map(\.tag))
		}
		let src = try #require(try await stub.vm(named: first.name).mounts.first {
			$0.tag == "src"
		})
		try await stub.removeMount(vm: first.name, mountID: src.id)
		served.append(try await stub.vm(named: first.name).mounts.map(\.tag))
		#expect(served == engine)
		let gone = try await #require(throws: MachmanError.self) {
			try await stub.removeMount(vm: first.name, mountID: src.id)
		}
		#expect(gone.code == .notFound)
	}

	// The file moves to the new tag and the field that named it follows (engine paths live in
	// a library, the stub's under /vm: both compare by role/tag/file).
	@Test("Q29: the stub's kernel re-tag serves what the engine serves")
	func kernelRetag() async throws {
		func files(_ boot: BootInfo) -> [String] {
			(boot.ownedKernels ?? []).map { "\($0.role.rawValue)/\($0.tag)/\($0.fileName)" }
		}
		func activeTag(_ boot: BootInfo) -> String? {
			boot.ownedKernels?.first { $0.path == boot.kernel?.kernelPath }?.tag
		}
		var engine: (files: [String], active: String?)?
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			let kernelsDir = vm.config.kernelsDirPath()
			let path = kernelsDir + "/kernel/v1/vmlinuz"
			try FileManager.default.createDirectory(
				atPath: kernelsDir + "/kernel/v1", withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: path))
			try vm.config.setKernelBoot(enabled: true)
			try vm.config.updateKernelSettings(LinuxKernelBoot(
				kernelPath: path, initialRamdiskPath: nil, commandLine: ""))
			try vm.config.renameKernelFile(path: path, to: "v2")
			let boot = api.info(for: vm).boot
			engine = (files(boot), activeTag(boot))
		}
		let path = "/vm/Parity/kernels/kernel/v1/vmlinuz"
		var info = StubMachman.makeInfo("Parity")
		info.boot = BootInfo(
			mode: .linuxKernel,
			kernel: KernelSettings(kernelPath: path, initrdPath: nil, commandLine: ""),
			macInstallState: nil, minCPUCount: nil, minMemoryBytes: nil,
			ownedKernels: [OwnedKernelFile(role: .kernel, tag: "v1", fileName: "vmlinuz",
				path: path)])
		let stub = StubMachman.serving([info])
		let after = try await stub.renameKernelFile(vm: "Parity", path: path, tag: "v2")
		#expect(files(after.boot) == engine?.files)
		#expect(activeTag(after.boot) == engine?.active)
		#expect(engine?.active == "v2")
	}
}
