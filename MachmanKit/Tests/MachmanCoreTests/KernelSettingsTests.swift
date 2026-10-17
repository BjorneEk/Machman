import Testing
import Foundation
import Virtualization
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct KernelSettingsTests {

	@Test func legacyConfigWithoutKernelSettingsDecodesToNil() throws {
		let legacy = """
		{
		  "name": "legacy",
		  "memorySize": 4096,
		  "cpuCount": 2,
		  "created": 0
		}
		""".data(using: .utf8)!
		let cfg = try JSONDecoder().decode(VMConfig.self, from: legacy)
		#expect(cfg.kernelSettings == nil)
	}

	@Test func hardwareFloorsOnlyForMacOS() {
		#expect(BootConfig.efi.hardwareFloors == nil)
		let kernel = BootConfig.linuxKernel(
			LinuxKernelBoot(kernelPath: "/k", initialRamdiskPath: nil, commandLine: ""))
		#expect(kernel.hardwareFloors == nil)
		let mac = BootConfig.macOS(
			MacOSBoot(installState: .installed, minimumCPUCount: 4, minimumMemorySize: 8))
		#expect(mac.hardwareFloors?.cpu == 4)
		#expect(mac.hardwareFloors?.mem == 8)
	}

	@Test func kernelBootToggleKeepsDraftAndSwitchesMode() throws {
		try VMTestDir.withRedirectedDir {
			let name = "kernel-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			let settings = LinuxKernelBoot(kernelPath: "/vmlinuz",
				initialRamdiskPath: "/initrd", commandLine: "console=hvc0")

			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(settings)
			#expect(cfg.boot == .linuxKernel(settings))
			#expect(cfg.kernelSettings == settings)

			try cfg.setKernelBoot(enabled: false)        // off: draft survives
			#expect(cfg.boot == .efi)
			#expect(cfg.kernelSettings == settings)

			let reloaded = try VMConfig.load(name: name)      // draft survives a reload too
			#expect(reloaded.boot == .efi)
			#expect(reloaded.kernelSettings == settings)

			try reloaded.setKernelBoot(enabled: true)    // re-enabling restores from the draft
			#expect(reloaded.boot == .linuxKernel(settings))
		}
	}

	// N3 (the user's review-4 note): kernel boot switched on creates an empty draft, and
	// switching it off kept that draft for good, so the tree drew parked Kernel and Initramfs
	// sections with nothing in them and no way to remove them. A draft holding nothing
	// (no file, no command line) goes with kernel boot.
	@Test("N3: kernel boot switched on and off with nothing set leaves no draft")
	func anEmptyDraftGoesWithKernelBoot() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "blank")
			let cfg = try VMConfig(name: "blank", memorySize: 2048, cpuCount: 2)
			try cfg.setKernelBoot(enabled: true)
			try cfg.setKernelBoot(enabled: false)
			#expect(cfg.boot == .efi)
			#expect(cfg.kernelSettings == nil)
			#expect(try VMConfig.load(name: "blank").kernelSettings == nil)
		}
	}

	@Test("N3: deleting the only kernel file while kernel boot is off leaves no draft")
	func deletingTheLastFileOfAParkedDraftDropsIt() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "parked")
			let cfg = try VMConfig(name: "parked", memorySize: 2048, cpuCount: 2)
			let kernelsDir = cfg.kernelsDirPath()
			let path = kernelsDir + "/kernel/v1/vmlinuz"
			try FileManager.default.createDirectory(
				atPath: kernelsDir + "/kernel/v1", withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: path))
			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(
				LinuxKernelBoot(kernelPath: path, initialRamdiskPath: nil, commandLine: ""))
			try cfg.setKernelBoot(enabled: false)
			#expect(cfg.kernelSettings?.kernelPath == path)   // a draft with a file is kept
			// LocalMachman.deleteKernelFile's config steps.
			try KernelStore.delete(path: path, kernelsDir: kernelsDir)
			try cfg.clearKernelReference(to: path)
			#expect(cfg.kernelSettings == nil)
		}
	}

	// K1 (review 4): a command line is something kept — the draft outlives kernel boot with it,
	// for the next kernel boot — while a line of only whitespace is no more than an empty one.
	@Test("N3: a parked draft that holds only a command line is kept")
	func aCommandLineKeepsTheParkedDraft() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "line")
			let cfg = try VMConfig(name: "line", memorySize: 2048, cpuCount: 2)
			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(
				LinuxKernelBoot(kernelPath: "", initialRamdiskPath: nil, commandLine: "quiet"))
			try cfg.setKernelBoot(enabled: false)
			#expect(cfg.kernelSettings?.commandLine == "quiet")
			#expect(try VMConfig.load(name: "line").kernelSettings?.commandLine == "quiet")

			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(
				LinuxKernelBoot(kernelPath: "", initialRamdiskPath: "", commandLine: " \n\t"))
			try cfg.setKernelBoot(enabled: false)
			#expect(cfg.kernelSettings == nil)
		}
	}

	// A parked draft emptied by a settings write (the last path deselected, the line blanked)
	// goes too; while kernel boot is on an empty draft stays — it is what the boot reads.
	@Test("N3: a settings write that empties a parked draft drops it")
	func emptyingAParkedDraftDropsIt() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "emptied")
			let cfg = try VMConfig(name: "emptied", memorySize: 2048, cpuCount: 2)
			let empty = LinuxKernelBoot(kernelPath: "", initialRamdiskPath: nil, commandLine: "")
			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(empty)
			#expect(cfg.kernelSettings == empty)
			#expect(cfg.boot == .linuxKernel(empty))
			try cfg.updateKernelSettings(
				LinuxKernelBoot(kernelPath: "/vmlinuz", initialRamdiskPath: nil, commandLine: ""))
			try cfg.setKernelBoot(enabled: false)
			#expect(cfg.kernelSettings?.kernelPath == "/vmlinuz")
			try cfg.updateKernelSettings(empty)
			#expect(cfg.boot == .efi)
			#expect(cfg.kernelSettings == nil)
			#expect(try VMConfig.load(name: "emptied").kernelSettings == nil)
		}
	}

	// D31 (review 4): a switch to macOS kept the kernel files and draft but listed neither, so
	// <vm>/kernels stayed with no way to delete it. Both are listed in macOS mode now (K3: kept,
	// deletable), and a delete there clears the field that named the file like anywhere else.
	@Test("D31: a macOS VM keeps and lists its kernel files and draft") @MainActor
	func aMacOSVMListsItsKernelFiles() throws {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			let src = TestEnvironment.scratch + "mac-kernel-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let kernelsDir = vm.config.kernelsDirPath()
			let path = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: kernelsDir, tag: "6.12")
			try vm.config.setKernelBoot(enabled: true)
			try vm.config.updateKernelSettings(
				LinuxKernelBoot(kernelPath: path, initialRamdiskPath: nil, commandLine: "quiet"))
			vm.config.boot = .macOS(
				MacOSBoot(installState: .installed, minimumCPUCount: 4, minimumMemorySize: 8))
			try vm.config.saveVMConfig()

			let listed = api.info(for: vm).boot
			#expect(listed.mode == .macOS)
			#expect(listed.ownedKernels?.map(\.path) == [path])
			#expect(listed.kernel?.kernelPath == path)

			// LocalMachman.deleteKernelFile's config steps.
			try KernelStore.delete(path: path, kernelsDir: kernelsDir)
			try vm.config.clearKernelReference(to: path)
			let after = api.info(for: vm).boot
			#expect(after.mode == .macOS)
			#expect(after.ownedKernels == nil)
			#expect(after.kernel
				== KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "quiet"))
		}
	}

	// C1: a rename moves the directory the owned kernel paths embed — they must follow, in
	// the draft AND the live boot payload, while external paths stay put.
	@Test func renameRepointsOwnedKernelPaths() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "before")
			let cfg = try VMConfig(name: "before", memorySize: 2048, cpuCount: 2)
			let kernelDir = machmanVMDir + "/before/kernels/kernel/v1"
			try FileManager.default.createDirectory(
				atPath: kernelDir, withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: kernelDir + "/vmlinuz"))
			let settings = LinuxKernelBoot(
				kernelPath: kernelDir + "/vmlinuz",
				initialRamdiskPath: "/outside/initrd", commandLine: "console=hvc0")
			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(settings)

			try cfg.rename(to: "after")

			let moved = machmanVMDir + "/after/kernels/kernel/v1/vmlinuz"
			let reloaded = try VMConfig.load(name: "after")
			#expect(reloaded.kernelSettings?.kernelPath == moved)
			#expect(reloaded.kernelSettings?.initialRamdiskPath == "/outside/initrd")
			guard case .linuxKernel(let live) = reloaded.boot else {
				Issue.record("expected a kernel boot")
				return
			}
			#expect(live.kernelPath == moved)
			#expect(FileManager.default.fileExists(atPath: moved))
		}
	}

	// D28: an enabled override on the active kernel file was saved and listed, but the boot read
	// the VM command line: nothing at start looked at the overrides.
	@Test("D28: the active kernel's enabled override is the command line its boot reads")
	func theActiveKernelsOverrideIsTheBootsCommandLine() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kline")
			let cfg = try VMConfig(name: "kline", memorySize: 2048, cpuCount: 2)
			let src = TestEnvironment.scratch + "kline-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let active = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "a")
			let other = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "b")
			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(LinuxKernelBoot(
				kernelPath: active, initialRamdiskPath: nil, commandLine: "console=hvc0"))
			func bootLine(_ config: VMConfig) throws -> String? {
				(try config.makeBootLoader() as? VZLinuxBootLoader)?.commandLine
			}

			// Another kernel file's override is not this boot's.
			try cfg.setKernelOverride(forFileAt: other, commandLine: "other", enabled: true)
			#expect(try bootLine(cfg) == "console=hvc0")
			try cfg.setKernelOverride(forFileAt: active, commandLine: "quiet", enabled: true)
			#expect(try bootLine(cfg) == "quiet")
			#expect(try bootLine(try VMConfig.load(name: "kline")) == "quiet")
			try cfg.setKernelOverride(forFileAt: active, commandLine: nil, enabled: false)
			#expect(try bootLine(cfg) == "console=hvc0")
		}
	}

	// D21: re-tagging the active kernel updated the draft but not the live boot payload, so
	// the next start failed with "Kernel image not found: …/kernel/v1/…"; and the override
	// moved to a key built from the tag trimmed of spaces only, while the file moved to one
	// trimmed of newlines too — orphaning it.
	@Test func retaggingTheActiveKernelKeepsBootOnIt() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kboot")
			let cfg = try VMConfig(name: "kboot", memorySize: 2048, cpuCount: 2)
			let src = TestEnvironment.scratch + "retag-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let file = (src as NSString).lastPathComponent
			let old = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "v1")
			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(LinuxKernelBoot(
				kernelPath: old, initialRamdiskPath: nil, commandLine: "console=hvc0"))
			try cfg.setKernelOverride(forFileAt: old, commandLine: "quiet", enabled: true)

			let new = try cfg.renameKernelFile(path: old, to: "v2\n")

			#expect(new == cfg.kernelsDirPath() + "/kernel/v2/" + file)
			for config in [cfg, try VMConfig.load(name: "kboot")] {
				#expect(config.kernelSettings?.kernelPath == new)
				guard case .linuxKernel(let live) = config.boot else {
					Issue.record("expected a kernel boot")
					return
				}
				#expect(live.kernelPath == new)
				let loader = try config.makeBootLoader() as? VZLinuxBootLoader
				#expect(loader?.kernelURL.path == new)
				#expect(config.kernelOverrides.keys.sorted() == ["kernel/v2/" + file])
			}
		}
	}

	// C11: the kernel-boot toggle can't replace a boot mode a newer Machman wrote — the
	// refusal says why (not the macOS-installed text BootConfigError maps to).
	@Test func aNewerBootModeRefusesTheKernelBootToggle() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "newer")
			let cfg = try VMConfig(name: "newer", memorySize: 2048, cpuCount: 2)
			cfg.boot = try JSONDecoder().decode(
				BootConfig.self, from: Data(#"{"bhyve":{"_0":{"x":1}}}"#.utf8))
			try cfg.saveVMConfig()
			for enabled in [true, false] {
				#expect(throws: MachmanError.self) { try cfg.setKernelBoot(enabled: enabled) }
			}
			#expect(try VMConfig.load(name: "newer").boot == cfg.boot)
			guard case .unknown = cfg.boot else {
				Issue.record("the boot mode was replaced")
				return
			}
		}
	}

	@Test func installedMacOSRefusesKernelBootToggle() throws {
		try VMTestDir.withRedirectedDir {
			let name = "locked-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			cfg.boot = .macOS(MacOSBoot(installState: .installed,
				minimumCPUCount: 4, minimumMemorySize: 8))
			#expect(throws: BootConfigError.macOSLocked) {
				try cfg.setKernelBoot(enabled: true)
			}
			#expect(throws: BootConfigError.macOSLocked) {
				try cfg.setKernelBoot(enabled: false)
			}
		}
	}
}
