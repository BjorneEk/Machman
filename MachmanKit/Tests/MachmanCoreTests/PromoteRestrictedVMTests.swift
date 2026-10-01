//
//  PromoteRestrictedVMTests.swift
//  MachmanTests
//
//  The vmhost half of vm.safeSave: a restricted registry pointed at a shadow run root
//  renames its VM into the library and re-keys itself. The redirected machmanVMDir plays the
//  run root; a sibling tmp dir plays the library; a bare VMRuntime (no VZ) marks the VM
//  "running" for the guard.
//

import Testing
import Foundation
import Virtualization
import MachmanAPI
@testable import MachmanCore

struct PromoteRestrictedVMTests {
	// Runs inside the redirect: machmanVMDir = run root. Returns (registry, library).
	@MainActor
	private func makeSafeHost(
		promotionLibrary: Bool = true, running: Bool = true, macOS: Bool = false
	) throws -> (VMRegistry, String) {
		let library = machmanVMDir + "-lib"
		try FileManager.default.createDirectory(
			atPath: library, withIntermediateDirectories: true)
		try VMConfig.createNewVMDirectory(name: "alpha")
		let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
		cfg.macAddress = "aa:bb:cc:dd:ee:99"
		if macOS {
			cfg.boot = .macOS(MacOSBoot(
				installState: .installed, minimumCPUCount: 2, minimumMemorySize: 2048))
		}
		try cfg.saveVMConfig()
		try Data("vmid".utf8)
			.write(to: URL(fileURLWithPath: machmanVMDir + "/alpha/vm_identifier"))
		let registry = VMRegistry(
			only: "alpha", promotionLibrary: promotionLibrary ? library : nil)
		if running, let vm = registry.vm(named: "alpha") {
			vm.runtime = VMRuntime(config: vm.config, events: registry.events)
		}
		return (registry, library)
	}

	@Test @MainActor func promotionMovesRekeysAndMintsFreshIdentity() throws {
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost()
			defer { try? FileManager.default.removeItem(atPath: library) }
			let runRoot = machmanVMDir
			let before = Date()

			let promoted = try registry.promoteRestrictedVM(to: "kept")

			let fm = FileManager.default
			#expect(fm.fileExists(atPath: library + "/kept/config"))
			#expect(!fm.fileExists(atPath: runRoot))               // run root fully gone
			#expect(machmanVMDir == library)                       // global re-pointed
			#expect(registry.restrictedName == "kept")
			#expect(registry.vm(named: "kept") === promoted)
			#expect(registry.vm(named: "alpha") == nil)
			#expect(promoted.config.name == "kept")

			let saved = try JSONDecoder().decode(
				VMConfig.self,
				from: Data(contentsOf: URL(fileURLWithPath: library + "/kept/config")))
			#expect(saved.name == "kept")
			#expect(saved.macAddress != "aa:bb:cc:dd:ee:99")       // fresh MAC persisted
			#expect(saved.created >= before)                       // a new VM, born now
			#expect(saved.totalRuntimeSeconds == 0)
			#expect(!fm.fileExists(atPath: library + "/kept/vm_identifier"))
		}
	}

	// C15: promotion takes a name through the same VM-name rule as rename and copy.
	@Test @MainActor func promotionRefusesHiddenAndControlNames() throws {
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost()
			defer { try? FileManager.default.removeItem(atPath: library) }
			let runRoot = machmanVMDir
			for bad in [".kept", "a\nb", " kept"] {
				let error = try #require(throws: MachmanError.self, "\(bad)") {
					try registry.promoteRestrictedVM(to: bad)
				}
				#expect(error.code == .invalidArgument)
			}
			#expect(FileManager.default.fileExists(atPath: runRoot + "/alpha/config"))
			#expect(registry.restrictedName == "alpha")
			#expect(try FileManager.default.contentsOfDirectory(atPath: library).isEmpty)
		}
	}

	@Test @MainActor func promotionMintsAFreshMacMachineID() throws {
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost(macOS: true)
			defer { try? FileManager.default.removeItem(atPath: library) }
			let sourceID = VZMacMachineIdentifier().dataRepresentation
			try sourceID.write(
				to: URL(fileURLWithPath: machmanVMDir + "/alpha/mac_machine_id"))

			_ = try registry.promoteRestrictedVM(to: "kept")

			let newID = try Data(
				contentsOf: URL(fileURLWithPath: library + "/kept/mac_machine_id"))
			#expect(newID != sourceID)
			#expect(VZMacMachineIdentifier(dataRepresentation: newID) != nil)
		}
	}

	// C1: the shadow's owned kernel paths point into the run root, which promotion moves
	// (then deletes) — the promoted config must point into the library.
	@Test @MainActor func promotionRepointsOwnedKernelPaths() throws {
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost()
			defer { try? FileManager.default.removeItem(atPath: library) }
			let vm = try #require(registry.vm(named: "alpha"))
			let kernelDir = machmanVMDir + "/alpha/kernels/kernel/v1"
			try FileManager.default.createDirectory(
				atPath: kernelDir, withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: kernelDir + "/vmlinuz"))
			let settings = LinuxKernelBoot(
				kernelPath: kernelDir + "/vmlinuz", initialRamdiskPath: nil,
				commandLine: "console=hvc0")
			vm.config.kernelSettings = settings
			vm.config.boot = .linuxKernel(settings)
			try vm.config.saveVMConfig()

			_ = try registry.promoteRestrictedVM(to: "kept")

			let moved = library + "/kept/kernels/kernel/v1/vmlinuz"
			let saved = try JSONDecoder().decode(
				VMConfig.self,
				from: Data(contentsOf: URL(fileURLWithPath: library + "/kept/config")))
			#expect(saved.kernelSettings?.kernelPath == moved)
			guard case .linuxKernel(let live) = saved.boot else {
				Issue.record("expected a kernel boot")
				return
			}
			#expect(live.kernelPath == moved)
			#expect(FileManager.default.fileExists(atPath: moved))
		}
	}

	// C2/C3/C4/C8 at the promotion seam: the shadow carried the source's ssh block
	// verbatim; becoming a new VM resets the instance identity, the vm.copy rule.
	@Test @MainActor func promotionResetsSSHInstanceIdentity() throws {
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost()
			defer { try? FileManager.default.removeItem(atPath: library) }
			let vm = try #require(registry.vm(named: "alpha"))
			var ssh = SSHConfig()
			ssh.integrationEnabled = true
			ssh.guestUser = "gustaf"
			ssh.alias = "dev"
			ssh.lastAddress = "192.168.64.9"
			ssh.guestHostname = "src-box"
			ssh.guestHostKey = "ssh-ed25519 AAAA src"
			ssh.reversePublicKey = "ssh-ed25519 BBBB guest"
			ssh.reverseState = SSHInfo.ReverseState.approved.rawValue
			ssh.marker = "machman-cafe"
			vm.config.ssh = ssh
			try vm.config.saveVMConfig()
			let sshDir = machmanVMDir + "/alpha/ssh"
			try FileManager.default.createDirectory(
				atPath: sshDir, withIntermediateDirectories: true)
			try Data("pin".utf8).write(to: URL(fileURLWithPath: sshDir + "/known_hosts"))

			_ = try registry.promoteRestrictedVM(to: "kept")

			let saved = try JSONDecoder().decode(
				VMConfig.self,
				from: Data(contentsOf: URL(fileURLWithPath: library + "/kept/config")))
			let kept = try #require(saved.ssh)
			#expect(kept.alias == nil)
			#expect(kept.lastAddress == nil)
			#expect(kept.guestHostname == nil)
			#expect(kept.guestHostKey == nil)
			#expect(kept.reversePublicKey == nil)
			#expect(kept.reverseStateValue == .none)
			#expect(kept.marker == nil)
			#expect(kept.integrationEnabled == true)
			#expect(kept.guestUser == "gustaf")
			#expect(!FileManager.default
				.fileExists(atPath: library + "/kept/ssh/known_hosts"))
		}
	}

	@Test @MainActor func promotionRefusals() throws {
		// No promotion library (an unsafe or launchd vmhost): refused.
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost(promotionLibrary: false)
			defer { try? FileManager.default.removeItem(atPath: library) }
			#expect(throws: MachmanError.self) {
				try registry.promoteRestrictedVM(to: "kept")
			}
		}
		// Destination taken: refused, nothing moved.
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost()
			defer { try? FileManager.default.removeItem(atPath: library) }
			try FileManager.default.createDirectory(
				atPath: library + "/kept", withIntermediateDirectories: true)
			#expect(throws: MachmanError.self) {
				try registry.promoteRestrictedVM(to: "kept")
			}
			#expect(FileManager.default.fileExists(atPath: machmanVMDir + "/alpha/config"))
		}
		// The safe run already ended (no runtime): refused.
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost(running: false)
			defer { try? FileManager.default.removeItem(atPath: library) }
			#expect(throws: MachmanError.self) {
				try registry.promoteRestrictedVM(to: "kept")
			}
		}
	}
}
