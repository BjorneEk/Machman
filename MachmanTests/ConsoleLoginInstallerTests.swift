//
//  ConsoleLoginInstallerTests.swift
//  MachmanTests
//
//  The macOS-guest login installer payload: script content, enabled-compacted port
//  naming, the generated machman.env (the script itself is parameterless), the on-disk
//  write, and the mac-only gates.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct ConsoleLoginInstallerTests {

	private var script: String { ConsoleLoginInstaller.script.text }

	@Test func scriptCarriesPlistsAndUninstall() {
		let s = script
		#expect(s.hasPrefix("#!/bin/sh"))
		#expect(s.contains(#"PREFIX="com.machman.console-getty""#))
		#expect(s.contains("--uninstall"))
		#expect(s.contains("<string>/usr/libexec/getty</string>"))
		#expect(s.contains("<string>std.115200</string>"))
		#expect(s.contains("launchctl bootstrap system"))
		#expect(s.contains("<key>KeepAlive</key>"))
		// The heredoc terminator must sit at column 0 or sh never ends the plist.
		#expect(s.contains("\nPLIST\n"))
		// Parameters ride machman.env, never the script text — and a lone copy of the
		// script says so instead of failing obscurely.
		#expect(s.contains(#". "$PAYLOAD_DIR/machman.env""#))
		#expect(s.contains("machman.env is missing"))
		#expect(s.contains("no consoles attached"))
		// The script owns its version; Swift reads it back.
		#expect(ConsoleLoginInstaller.script.version == 1)
	}

	// A quoting/heredoc slip would otherwise only surface inside a guest — parse the
	// script with the same interpreter the guest uses (sh -n: no execution).
	@Test func scriptParsesUnderSh() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("machman-installer-\(UUID().uuidString).sh")
		try script.write(to: url, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: url) }
		let sh = Process()
		sh.executableURL = URL(fileURLWithPath: "/bin/sh")
		sh.arguments = ["-n", url.path]
		try sh.run()
		sh.waitUntilExit()
		#expect(sh.terminationStatus == 0)
	}

	@Test @MainActor func portsCompactToEnabledConsoles() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "compact")
			let vm = try VMConfig(name: "compact", memorySize: 1 << 30, cpuCount: 2)
			try vm.addConsolePort()               // console0 (seeded) + console1
			#expect(ConsoleLoginInstaller.ports(for: vm) == ["cu.virtio", "cu.virtio1"])
			// Disabling one compacts the numbering — matching what the guest sees.
			vm.consolePorts[0].enabled = false
			#expect(ConsoleLoginInstaller.ports(for: vm) == ["cu.virtio"])
		}
	}

	@Test @MainActor func environmentCarriesPortsAndName() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "envvm")
			let vm = try VMConfig(name: "envvm", memorySize: 1 << 30, cpuCount: 2)
			try vm.addConsolePort()
			let env = try ConsoleLoginInstaller.environment(for: vm)
			#expect(env["VM_NAME"] == "envvm")
			#expect(env["PORTS"] == "cu.virtio cu.virtio1")
			// No enabled consoles is a valid state — the script prints its own advice.
			vm.consolePorts.indices.forEach { vm.consolePorts[$0].enabled = false }
			#expect(try ConsoleLoginInstaller.environment(for: vm)["PORTS"] == "")
		}
	}

	@Test @MainActor func payloadWritesUnderTheVMDir() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "machost")
			let vm = try VMConfig(name: "machost", memorySize: 1 << 30, cpuCount: 2)
			let dir = try ConsoleLoginInstaller.writePayload(for: vm)
			#expect(dir.path.hasPrefix(vm.vmDirPath()))
			let script = dir.appendingPathComponent(ConsoleLoginInstaller.scriptName)
			let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
			#expect((attrs[.posixPermissions] as? Int) == 0o755)
			// The per-VM half lives beside it, shell-quoted.
			let env = try String(
				contentsOf: dir.appendingPathComponent(
					GuestInstallerWriter.environmentFileName), encoding: .utf8)
			#expect(env.contains("PORTS='cu.virtio'"))    // the one seeded console
			#expect(env.contains("VM_NAME='machost'"))
		}
	}

	@Test @MainActor func macOnlyGates() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "efi")
			let vm = try VMConfig(name: "efi", memorySize: 1 << 30, cpuCount: 2)
			// Add-time gate: an EFI VM refuses the kind.
			#expect(throws: MachmanError.self) {
				try LocalMachman.validateDeviceKind(.consoleLoginInstaller, for: vm)
			}
			// Boot-time gate: forced into config anyway → skipped with a warning.
			vm.devices.append(GuestDevice(kind: .consoleLoginInstaller))
			let resolved = vm.resolvedDevices()
			#expect(resolved.attach[.consoleLoginInstaller] == nil)
			#expect(resolved.warnings.contains { $0.contains("login installer") })
		}
	}
}
