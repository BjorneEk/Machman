import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct BootConfigTests {

	@Test func bootConfigCasesRoundTrip() throws {
		let cases: [BootConfig] = [
			.efi,
			.linuxKernel(LinuxKernelBoot(kernelPath: "/boot/vmlinuz",
				initialRamdiskPath: "/boot/initrd.img", commandLine: "console=hvc0 root=/dev/vda1 rw")),
			.linuxKernel(LinuxKernelBoot(kernelPath: "/k", initialRamdiskPath: nil, commandLine: "")),
			.macOS(MacOSBoot(installState: .installing, minimumCPUCount: 2, minimumMemorySize: 4_000_000_000)),
			.macOS(MacOSBoot(installState: .installed, minimumCPUCount: 4, minimumMemorySize: 8_000_000_000)),
			.macOS(MacOSBoot(installState: .failed("boom"), minimumCPUCount: 1, minimumMemorySize: 1)),
		]
		for c in cases {
			let data = try JSONEncoder().encode(c)
			let back = try JSONDecoder().decode(BootConfig.self, from: data)
			#expect(back == c)
		}
	}

	// A config written before boot modes existed has no "boot" key; it must load as .efi.
	@Test func legacyConfigWithoutBootDecodesToEFI() throws {
		let legacy = """
		{
		  "name": "legacy",
		  "memorySize": 4096,
		  "cpuCount": 2,
		  "state": "stopped",
		  "created": 0,
		  "mountPoints": [],
		  "disks": []
		}
		""".data(using: .utf8)!
		let cfg = try JSONDecoder().decode(VMConfig.self, from: legacy)
		#expect(cfg.boot == .efi)
	}

	// Exercises the real saveVMConfig() -> load(name:) path.
	@Test func savedBootSurvivesReload() throws {
		try VMTestDir.withRedirectedDir {
			let name = "rt-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			cfg.boot = .linuxKernel(LinuxKernelBoot(kernelPath: "/vmlinuz",
				initialRamdiskPath: nil, commandLine: "console=hvc0 root=/dev/vda1 rw"))
			try cfg.saveVMConfig()

			let reloaded = try VMConfig.load(name: name)
			#expect(reloaded.boot == cfg.boot)
		}
	}

	// The on-disk shapes are FROZEN: every config on disk carries what the synthesized enum
	// coding wrote, captured from that coder before the coding went explicit (D26).
	@Test func knownBootModesKeepTheirOnDiskShape() throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		func mac(_ state: MachmanCore.MacInstallState) -> BootConfig {
			.macOS(MacOSBoot(installState: state, minimumCPUCount: 2, minimumMemorySize: 3))
		}
		let floors = #""minimumCPUCount":2,"minimumMemorySize":3}}}"#
		let golden: [(BootConfig, String)] = [
			(.efi, #"{"efi":{}}"#),
			(.linuxKernel(LinuxKernelBoot(
				kernelPath: "/k", initialRamdiskPath: nil, commandLine: "c")),
				#"{"linuxKernel":{"_0":{"commandLine":"c","kernelPath":"\/k"}}}"#),
			(.linuxKernel(LinuxKernelBoot(
				kernelPath: "/k", initialRamdiskPath: "/i", commandLine: "c")),
				#"{"linuxKernel":{"_0":{"commandLine":"c","initialRamdiskPath":"\/i","#
					+ #""kernelPath":"\/k"}}}"#),
			(mac(.installing), #"{"macOS":{"_0":{"installState":{"installing":{}},"# + floors),
			(mac(.installed), #"{"macOS":{"_0":{"installState":{"installed":{}},"# + floors),
			(mac(.failed("x")),
				#"{"macOS":{"_0":{"installState":{"failed":{"_0":"x"}},"# + floors),
		]
		for (boot, json) in golden {
			#expect(String(decoding: try encoder.encode(boot), as: UTF8.self) == json)
			#expect(try JSONDecoder().decode(BootConfig.self, from: Data(json.utf8)) == boot)
		}
	}

	// A boot mode a newer Machman wrote: every JSON kind, a UInt64 past Int64, an escaped path.
	private static let newerBoot = #"{"bhyve":{"_0":{"firmware":"\/Users\/x\/fw.bin","#
		+ #""cores":-3,"big":18446744073709551615,"ratio":1.5e-07,"#
		+ #""flags":[true,null,"x",0.1],"nested":{},"list":[]}}}"#

	private func writeConfig(named name: String, boot: String = newerBoot) throws {
		try VMConfig.createNewVMDirectory(name: name)
		let config = #"{"name":"\#(name)","memorySize":2147483648,"cpuCount":2,"#
			+ #""created":1000,"macAddress":"aa:bb:cc:dd:ee:01","boot":\#(boot),"#
			+ #""devices":[],"consolePorts":[],"uartPorts":[]}"#
		try Data(config.utf8).write(to: URL(fileURLWithPath: "\(machmanVMDir)/\(name)/config"))
	}

	private func savedBoot(of config: VMConfig) throws -> NSDictionary? {
		let saved = try JSONSerialization.jsonObject(
			with: Data(contentsOf: URL(fileURLWithPath: config.configPath()))) as? NSDictionary
		return saved?["boot"] as? NSDictionary
	}

	// D26: a boot mode a newer Machman wrote failed the whole config decode, so the VM vanished
	// from the list (and ⌘N could then write over its folder, D19). It loads as .unknown now,
	// and every save writes the value back as read — each key, string and number.
	@Test @MainActor func aNewerBootModeIsListedAndKept() throws {
		try VMTestDir.withRedirectedDir {
			try writeConfig(named: "newer")
			let registry = VMRegistry()
			let vm = try #require(registry.vm(named: "newer"))
			guard case .unknown = vm.config.boot else {
				Issue.record("expected a boot mode this build can't read")
				return
			}
			#expect(LocalMachman(registry: registry).info(for: vm).boot.mode == .unknown)

			try vm.config.setCPUCount(1)
			let original = try JSONSerialization.jsonObject(
				with: Data(Self.newerBoot.utf8)) as? NSDictionary
			#expect(try savedBoot(of: vm.config) == original)
			#expect(try VMConfig.load(name: "newer").boot == vm.config.boot)
		}
	}

	// A known mode whose payload this build can't read — a newer install state — is kept
	// whole the same way.
	@Test func aNewerMacInstallStateKeepsTheWholeBootMode() throws {
		let json = #"{"macOS":{"_0":{"installState":{"upgrading":{}},"#
			+ #""minimumCPUCount":2,"minimumMemorySize":3}}}"#
		let boot = try JSONDecoder().decode(BootConfig.self, from: Data(json.utf8))
		guard case .unknown = boot else {
			Issue.record("expected a boot mode this build can't read")
			return
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		#expect(String(decoding: try encoder.encode(boot), as: UTF8.self) == json)
		#expect(!boot.isMacInstalled)
		#expect(boot.hardwareFloors == nil)
		#expect(InstallSession.phase(for: boot, hasActiveInstall: false).kind == .idle)
	}

	// C11: the VM can't start — the vmhost's build refuses before any VZ object exists.
	@Test func aNewerBootModeCantStart() throws {
		try VMTestDir.withRedirectedDir {
			try writeConfig(named: "newer")
			let config = try VMConfig.load(name: "newer")
			let refusal = "A newer version of Machman set this VM\u{2019}s boot mode"
			for start in [
				{ try config.requireStartable() },
				{ _ = try config.makeVZVirtualMachineConfiguration() },
				{ _ = try config.makePlatform() },
				{ _ = try config.makeBootLoader() },
			] as [() throws -> Void] {
				let error = try #require(throws: MachmanError.self) { try start() }
				#expect(error.code == .invalidState)
				#expect(error.message == refusal)
			}
			#expect(!FileManager.default.fileExists(atPath: config.vmIdentifierPath()))
		}
	}
}
