import Testing
import Foundation
import Virtualization
import MachmanAPI
@testable import MachmanCore

// Persisted guest-device config (1.0.4): the implied-set migration, unknown-kind
// preservation, enabled flags on disks/mounts/serial, and kernel overrides. Pure VMConfig
// (no VZ), under a redirected data dir — the SerialConfigTests pattern.
struct DeviceConfigTests {

	private func makeVM(_ name: String) throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		return try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
	}

	private func configPath(_ name: String) -> String { "\(machmanVMDir)/\(name)/config" }

	private func rewriteJSON(_ name: String, _ mutate: (inout [String: Any]) -> Void) throws {
		let url = URL(fileURLWithPath: configPath(name))
		var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
		mutate(&obj)
		try JSONSerialization.data(withJSONObject: obj).write(to: url)
	}

	@Test func newVMSeedsImpliedEFIDevices() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("alpha")
			let kinds = vm.devices.map(\.deviceKind)
			#expect(kinds == ImpliedDevices.kinds(macGuest: false))
			#expect(kinds.contains(.clipboard))
			#expect(!kinds.contains(.trackpad))
			let allEnabled = vm.devices.allSatisfy(\.enabled)
			#expect(allEnabled)
		}
	}

	@Test func legacyConfigGainsImpliedSetPerBoot() throws {
		try VMTestDir.withRedirectedDir {
			_ = try makeVM("legacy")
			try rewriteJSON("legacy") { $0.removeValue(forKey: "devices") }
			let efi = try VMConfig.load(name: "legacy")
			#expect(efi.devices.map(\.deviceKind) == ImpliedDevices.kinds(macGuest: false))

			let mac = try makeVM("legacymac")
			mac.boot = .macOS(MacOSBoot(
				installState: .installed, minimumCPUCount: 4, minimumMemorySize: 4 << 30))
			try mac.saveVMConfig()
			try rewriteJSON("legacymac") { $0.removeValue(forKey: "devices") }
			let reloaded = try VMConfig.load(name: "legacymac")
			#expect(reloaded.devices.map(\.deviceKind) == ImpliedDevices.kinds(macGuest: true))
			#expect(reloaded.devices.map(\.deviceKind).contains(.trackpad))
		}
	}

	@Test func intentionalEmptyDevicesStayEmpty() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("bare")
			vm.devices = []
			try vm.saveVMConfig()
			let reloaded = try VMConfig.load(name: "bare")
			#expect(reloaded.devices.isEmpty)   // NOT re-seeded: the key is present
		}
	}

	@Test func unknownDeviceKindSurvivesLoadAndSave() throws {
		try VMTestDir.withRedirectedDir {
			_ = try makeVM("future")
			try rewriteJSON("future") { obj in
				var devices = obj["devices"] as! [[String: Any]]
				devices.append(["kind": "quantumLink", "enabled": false])
				obj["devices"] = devices
			}
			let loaded = try VMConfig.load(name: "future")
			let quantum = loaded.devices.first { $0.kind == "quantumLink" }
			#expect(quantum != nil)
			#expect(quantum?.enabled == false)
			#expect(quantum?.deviceKind == .unknown)
			try loaded.saveVMConfig()
			let again = try VMConfig.load(name: "future")
			#expect(again.devices.contains { $0.kind == "quantumLink" })
		}
	}

	@Test func deviceSettingsPersist() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("gfx")
			var graphics = vm.devices.first { $0.deviceKind == .graphics }!
			graphics.displayWidthPixels = 1920
			graphics.displayHeightPixels = 1080
			graphics.enabled = false
			vm.devices[vm.devices.firstIndex { $0.deviceKind == .graphics }!] = graphics
			var clipboard = vm.devices.first { $0.deviceKind == .clipboard }!
			clipboard.sharesClipboard = false
			vm.devices[vm.devices.firstIndex { $0.deviceKind == .clipboard }!] = clipboard
			try vm.saveVMConfig()
			let reloaded = try VMConfig.load(name: "gfx")
			let g = reloaded.devices.first { $0.deviceKind == .graphics }
			#expect(g?.displayWidthPixels == 1920)
			#expect(g?.displayHeightPixels == 1080)
			#expect(g?.enabled == false)
			#expect(reloaded.devices.first { $0.deviceKind == .clipboard }?.sharesClipboard
				== false)
		}
	}

	// 1.0.10: the display's system-key-capture default persists raw, so a newer daemon's
	// future mode survives this daemon's load/save; the run default reads it as off.
	@Test func systemKeyCapturePersistsAndDefaults() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("keys")
			#expect(vm.systemKeyCaptureDefault == .off)   // unset
			let index = vm.devices.firstIndex { $0.deviceKind == .graphics }!
			vm.devices[index].systemKeyCapture = SystemKeyCapture.fullScreen.rawValue
			try vm.saveVMConfig()
			let reloaded = try VMConfig.load(name: "keys")
			#expect(reloaded.systemKeyCaptureDefault == .fullScreen)

			try rewriteJSON("keys") { obj in
				var devices = obj["devices"] as! [[String: Any]]
				let i = devices.firstIndex { $0["kind"] as? String == "graphics" }!
				devices[i]["systemKeyCapture"] = "whenFocused"
				obj["devices"] = devices
			}
			let future = try VMConfig.load(name: "keys")
			#expect(future.systemKeyCaptureDefault == .off)
			#expect(future.devices[index].systemKeyCaptureMode == .unknown)
			try future.saveVMConfig()
			let again = try VMConfig.load(name: "keys")
			#expect(again.devices[index].systemKeyCapture == "whenFocused")

			// No display device at all: nothing to capture for, so off.
			again.devices.removeAll { $0.deviceKind == .graphics }
			#expect(again.systemKeyCaptureDefault == .off)
		}
	}

	// vm.device.update takes the mode from the request — except an older client's .unknown
	// echo of a mode it could not read, which keeps the stored value instead of erasing it.
	@Test func systemKeyCaptureUpdateKeepsUnknown() {
		var stored = GuestDevice(kind: .graphics)
		stored.systemKeyCapture = "whenFocused"
		stored.displayWidthPixels = 1920

		let echo = LocalMachman.guestDevice(
			from: DeviceInfo(kind: .graphics, systemKeyCapture: .unknown), replacing: stored)
		#expect(echo.systemKeyCapture == "whenFocused")
		#expect(echo.displayWidthPixels == nil)   // everything else follows the request

		let set = LocalMachman.guestDevice(
			from: DeviceInfo(kind: .graphics, systemKeyCapture: .always), replacing: stored)
		#expect(set.systemKeyCapture == "always")
		let cleared = LocalMachman.guestDevice(
			from: DeviceInfo(kind: .graphics), replacing: stored)
		#expect(cleared.systemKeyCapture == nil)
	}

	@Test func enabledFlagsPersistOnDisksMountsSerial() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("flags")
			try vm.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: "/tmp/x.raw"))))
			try vm.addMountPoint(HostMountPoint(path: "/tmp", tag: "t"))
			try vm.addUartPort()
			vm.disks[0].enabled = false
			vm.mountPoints[0].enabled = false
			vm.consolePorts[0].enabled = false
			try vm.saveVMConfig()
			let reloaded = try VMConfig.load(name: "flags")
			#expect(reloaded.disks[0].enabled == false)
			#expect(reloaded.mountPoints[0].enabled == false)
			#expect(reloaded.consolePorts[0].enabled == false)
			#expect(reloaded.uartPorts[0].enabled)
			// Legacy entries without the key load as enabled.
			try rewriteJSON("flags") { obj in
				var disks = obj["disks"] as! [[String: Any]]
				disks[0].removeValue(forKey: "enabled")
				obj["disks"] = disks
			}
			let legacy = try VMConfig.load(name: "flags")
			#expect(legacy.disks[0].enabled)
		}
	}

	@Test func addMountPointValidatesTags() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("mtags")
			try vm.addMountPoint(HostMountPoint(path: "/tmp", tag: "data"))
			// A duplicate tag would trap the vmhost's share dictionary at start.
			#expect(throws: MachmanError.self) {
				try vm.addMountPoint(HostMountPoint(path: "/tmp/b", tag: "data"))
			}
			#expect(throws: MachmanError.self) {
				try vm.addMountPoint(HostMountPoint(path: "/tmp/c", tag: "   "))
			}
			// Whitespace trims into the stored tag.
			try vm.addMountPoint(HostMountPoint(path: "/tmp/d", tag: "  logs "))
			#expect(vm.mountPoints.map(\.tag) == ["data", "logs"])
			_ = vm.directoryShareDeviceConfig(mainTag: "host-share")   // must not trap
			// The login installer's share tag is reserved, add AND rename.
			#expect(throws: MachmanError.self) {
				try vm.addMountPoint(HostMountPoint(path: "/tmp/e", tag: "LoginInstaller"))
			}
			#expect(throws: MachmanError.self) {
				try vm.setMountTag(
					id: vm.mountPoints[0].id.uuidString, tag: "LoginInstaller")
			}
		}
	}

	// sshfs-kind mounts (1.0.7) never enter the share device — the guest mounts them
	// itself over its SSH link; the tag namespace stays shared across both kinds.
	@Test func sshfsMountsStayOutOfTheShare() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("mkinds")
			try vm.addMountPoint(HostMountPoint(path: "/tmp/a", tag: "data"))
			try vm.addMountPoint(HostMountPoint(
				path: "/tmp/b", tag: "docs", kind: MountKind.sshfs))
			let share = vm.directoryShareDeviceConfig(mainTag: "host-share")
			let directories = (share.share as? VZMultipleDirectoryShare)?.directories ?? [:]
			#expect(directories.keys.contains("data"))
			#expect(!directories.keys.contains("docs"))
			// One namespace: an sshfs mount's tag still blocks a virtiofs twin.
			#expect(throws: MachmanError.self) {
				try vm.addMountPoint(HostMountPoint(path: "/tmp/c", tag: "docs"))
			}
			// Switching kinds moves it in and out of the share.
			try vm.setMountKind(id: vm.mountPoints[1].id.uuidString, kind: MountKind.virtiofs)
			let after = vm.directoryShareDeviceConfig(mainTag: "host-share")
			let afterDirectories =
				(after.share as? VZMultipleDirectoryShare)?.directories ?? [:]
			#expect(afterDirectories.keys.contains("docs"))
		}
	}

	@Test func kernelOverridesPersistOnlyWhenPresent() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("kern")
			// No overrides -> the key stays out of the file entirely.
			let raw = try JSONSerialization.jsonObject(
				with: Data(contentsOf: URL(fileURLWithPath: configPath("kern"))))
				as! [String: Any]
			#expect(raw["kernelOverrides"] == nil)

			vm.kernelOverrides["kernel/janus/vmlinuz"] =
				KernelOverrideConfig(commandLine: "console=hvc0 quiet", enabled: true)
			try vm.saveVMConfig()
			let reloaded = try VMConfig.load(name: "kern")
			#expect(reloaded.kernelOverrides["kernel/janus/vmlinuz"]
				== KernelOverrideConfig(commandLine: "console=hvc0 quiet", enabled: true))
		}
	}

	@Test func nestedVirtualizationPersists() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("nested")
			#expect(!vm.nestedVirtualization)
			vm.nestedVirtualization = true
			try vm.saveVMConfig()
			let reloaded = try VMConfig.load(name: "nested")
			#expect(reloaded.nestedVirtualization)
		}
	}

	@Test func resolvedDevicesFilterAndWarn() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("resolve")   // implied EFI set incl. clipboard
			// Disable one device (silently honored), add misfits (warned).
			vm.devices[vm.devices.firstIndex { $0.deviceKind == .audioInput }!].enabled = false
			vm.devices.append(GuestDevice(kind: .trackpad))          // needs macOS guest
			var future = GuestDevice(kind: .entropy)
			future.kind = "quantumLink"                              // unknown kind
			vm.devices.append(future)
			let resolved = vm.resolvedDevices()
			#expect(resolved.attach[.audioInput] == nil)             // disabled: no warning
			#expect(resolved.attach[.trackpad] == nil)
			#expect(resolved.attach[.keyboard] != nil)
			#expect(resolved.attach[.clipboard] != nil)
			#expect(resolved.warnings.contains { $0.contains("trackpad") })
			#expect(resolved.warnings.contains { $0.contains("quantumLink") })
			#expect(!resolved.warnings.contains { $0.contains("audioInput") })
		}
	}

	@Test func enabledFilteringInAssembly() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("filter")
			// A single DISABLED referenced disk: diskArray must skip it without touching
			// the (nonexistent) file — attaching it would throw.
			try vm.addDisk(disk: VMDisk(kind: .fromUrl(URL(
				fileURLWithPath: "/nonexistent/ghost.raw"))))
			vm.disks[0].enabled = false
			let storage = try vm.diskArray()
			#expect(storage.isEmpty)
			// Disabled mounts drop out of the share.
			try vm.addMountPoint(HostMountPoint(path: "/tmp", tag: "t"))
			vm.mountPoints[0].enabled = false
			_ = vm.directoryShareDeviceConfig(mainTag: "host-share")
			// Disabled serial ports are not built; the remaining enabled ones renumber.
			try vm.addConsolePort()               // now console0, console1
			vm.consolePorts[0].enabled = false
			let serial = vm.serialPorts()
			#expect(serial.wiring.filter { $0.kind == .console }.count == 1)
			#expect(serial.wiring.first { $0.kind == .console }?.index == 1)
		}
	}

	@Test func kernelOverrideKeyIsVMRelative() throws {
		let file = OwnedKernelFile(
			role: .kernel, tag: "janus", fileName: "vmlinuz",
			path: "/anywhere/kernels/kernel/janus/vmlinuz")
		#expect(VMConfig.kernelOverrideKey(for: file) == "kernel/janus/vmlinuz")
	}
}
