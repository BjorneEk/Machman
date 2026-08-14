//
//  ConsoleLoginInstallerTests.swift
//  MachmanTests
//
//  The macOS-guest login installer payload: script content, enabled-compacted port
//  naming, the on-disk write, and the mac-only gates.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct ConsoleLoginInstallerTests {

	@Test func scriptCarriesPortsPlistsAndUninstall() {
		let s = ConsoleLoginInstaller.script(
			vmName: "mac", ports: ["cu.virtio", "cu.virtio1"])
		#expect(s.contains(#"PORTS="cu.virtio cu.virtio1""#))
		#expect(s.contains(#"PREFIX="com.machman.console-getty""#))
		#expect(s.contains("--uninstall"))
		#expect(s.contains("<string>/usr/libexec/getty</string>"))
		#expect(s.contains("<string>std.115200</string>"))
		#expect(s.contains("launchctl bootstrap system"))
		#expect(s.contains("<key>KeepAlive</key>"))
		// The heredoc terminator must sit at column 0 or sh never ends the plist.
		#expect(s.contains("\nPLIST\n"))
		#expect(s.hasPrefix("#!/bin/sh"))
	}

	@Test func scriptHandlesZeroConsoles() {
		let s = ConsoleLoginInstaller.script(vmName: "mac", ports: [])
		#expect(s.contains(#"PORTS="""#))
		#expect(s.contains("no consoles attached"))
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

	@Test @MainActor func payloadWritesUnderTheVMDir() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "machost")
			let vm = try VMConfig(name: "machost", memorySize: 1 << 30, cpuCount: 2)
			let dir = try ConsoleLoginInstaller.writePayload(for: vm)
			#expect(dir.path.hasPrefix(vm.vmDirPath()))
			let script = dir.appendingPathComponent(ConsoleLoginInstaller.scriptName)
			let body = try String(contentsOf: script, encoding: .utf8)
			#expect(body.contains(#"PORTS="cu.virtio""#))   // the one seeded console
			let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
			#expect((attrs[.posixPermissions] as? Int) == 0o755)
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
