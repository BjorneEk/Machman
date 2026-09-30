import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

// Persisted serial-port config: counts, per-port logging, the legacy→one-console migration,
// and the 10-port cap. Pure VMConfig (no VZ), under a redirected data dir.
struct SerialConfigTests {

	private func makeVM(_ name: String) throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		return try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
	}

	// Strip the serial keys from an on-disk config to simulate one written before the feature.
	private func stripSerialKeys(_ name: String) throws {
		let path = "\(machmanVMDir)/\(name)/config"
		var obj = try JSONSerialization.jsonObject(
			with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
		obj.removeValue(forKey: "consolePorts")
		obj.removeValue(forKey: "uartPorts")
		try JSONSerialization.data(withJSONObject: obj)
			.write(to: URL(fileURLWithPath: path))
	}

	@Test func newVMHasOneConsoleNoUart() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("alpha")
			#expect(vm.consolePorts.count == 1)
			#expect(vm.uartPorts.isEmpty)
			#expect(vm.consolePorts[0].logging == SerialLogConfig())
			#expect(SerialLogConfig().mode == .resetOnBoot)
			#expect(SerialLogConfig().maxBytes == nil)
		}
	}

	@Test func addAndRemovePersist() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("beta")
			try vm.addConsolePort()
			try vm.addUartPort()
			try vm.addUartPort()
			let a = try VMConfig.load(name: "beta")
			#expect(a.consolePorts.count == 2)
			#expect(a.uartPorts.count == 2)
			try a.removeLastConsolePort()
			try a.removeLastUartPort()
			let b = try VMConfig.load(name: "beta")
			#expect(b.consolePorts.count == 1)
			#expect(b.uartPorts.count == 1)
		}
	}

	// D5: a removed port takes its log file with it, so a port added later at the same
	// index starts fresh instead of inheriting the dead port's history.
	@Test func removingAPortRemovesItsLog() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("delta")
			try vm.addUartPort()   // console0 exists by default
			let consoleLog = vm.serialLogURL(kind: .console, index: 0)
			let uartLog = vm.serialLogURL(kind: .uart, index: 0)
			try Data("console history".utf8).write(to: consoleLog)
			try Data("uart history".utf8).write(to: uartLog)

			try vm.removeLastUartPort()
			#expect(!FileManager.default.fileExists(atPath: uartLog.path))
			#expect(FileManager.default.fileExists(atPath: consoleLog.path))  // sibling stays

			try vm.removeLastConsolePort()
			#expect(!FileManager.default.fileExists(atPath: consoleLog.path))
			try vm.addConsolePort()
			#expect(!FileManager.default.fileExists(atPath: consoleLog.path))
		}
	}

	@Test func intentionalZeroStaysZero() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("gamma")
			try vm.removeLastConsolePort()          // now 0 consoles, keys present
			let reloaded = try VMConfig.load(name: "gamma")
			#expect(reloaded.consolePorts.isEmpty)  // NOT re-seeded
			#expect(reloaded.uartPorts.isEmpty)
		}
	}

	@Test func legacyEfiConfigGainsOneConsole() throws {
		try VMTestDir.withRedirectedDir {
			_ = try makeVM("legacy")
			try stripSerialKeys("legacy")
			let reloaded = try VMConfig.load(name: "legacy")
			#expect(reloaded.consolePorts.count == 1)
			#expect(reloaded.uartPorts.isEmpty)
		}
	}

	@Test func legacyMacOSConfigGainsNoConsole() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("legacymac")
			vm.boot = .macOS(MacOSBoot(
				installState: .installed, minimumCPUCount: 4, minimumMemorySize: 4 << 30))
			try vm.saveVMConfig()
			try stripSerialKeys("legacymac")
			let reloaded = try VMConfig.load(name: "legacymac")
			#expect(reloaded.consolePorts.isEmpty)
			#expect(reloaded.uartPorts.isEmpty)
		}
	}

	@Test func serialPortsAreCappedAtTen() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("capped")   // starts with 1 console
			for _ in 0..<9 { try vm.addUartPort() }   // 1 + 9 = 10
			#expect(vm.consolePorts.count + vm.uartPorts.count == 10)
			#expect(throws: MachmanError.self) { try vm.addUartPort() }
			#expect(throws: MachmanError.self) { try vm.addConsolePort() }
		}
	}

	@Test func removingFromEmptyThrows() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("empty")
			try vm.removeLastConsolePort()
			#expect(throws: MachmanError.self) { try vm.removeLastConsolePort() }
			#expect(throws: MachmanError.self) { try vm.removeLastUartPort() }
		}
	}

	@Test func setLoggingPersistsAndValidatesIndex() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("logvm")
			try vm.addUartPort()
			try vm.setSerialLogging(
				kind: .console, index: 0,
				config: SerialLogConfig(mode: .continuous, maxBytes: 1024))
			try vm.setSerialLogging(kind: .uart, index: 0, config: SerialLogConfig(mode: .disabled))
			let reloaded = try VMConfig.load(name: "logvm")
			#expect(reloaded.consolePorts[0].logging == SerialLogConfig(mode: .continuous, maxBytes: 1024))
			#expect(reloaded.uartPorts[0].logging.mode == .disabled)
			#expect(throws: MachmanError.self) {
				try reloaded.setSerialLogging(kind: .console, index: 5, config: SerialLogConfig())
			}
		}
	}

	// macOS 26.6.1 gated the private PL011/16550 serial devices behind the
	// com.apple.private.virtualization entitlement (the helper traps decoding them at start for an
	// unentitled host). The gate must reject exactly [26.6.1, ∞) — a wrong boundary either crashes
	// every uart VM start or silently disables uarts on working systems.
	@Test func privateSerialRejectionBoundary() {
		func v(_ a: Int, _ b: Int, _ c: Int) -> OperatingSystemVersion {
			OperatingSystemVersion(majorVersion: a, minorVersion: b, patchVersion: c)
		}
		#expect(!VMConfig.privateSerialRejected(by: v(15, 7, 2)))
		#expect(!VMConfig.privateSerialRejected(by: v(26, 5, 9)))
		#expect(!VMConfig.privateSerialRejected(by: v(26, 6, 0)))
		#expect(VMConfig.privateSerialRejected(by: v(26, 6, 1)))
		#expect(VMConfig.privateSerialRejected(by: v(26, 6, 2)))
		#expect(VMConfig.privateSerialRejected(by: v(26, 7, 0)))
		#expect(VMConfig.privateSerialRejected(by: v(27, 0, 0)))
	}

	// The wire constant and the runtime gate must agree: SerialPortInfo.unavailable.sinceOSVersion
	// and privateSerialRejected() both derive from SerialPortSupport.privateUARTGatedSince.
	@Test func gateConstantMatchesBoundaryAndReason() {
		#expect(SerialPortSupport.privateUARTGatedSinceDisplay == "26.6.1")
		let g = SerialPortSupport.privateUARTGatedSince
		#expect(VMConfig.privateSerialRejected(by: g))
		#expect(!VMConfig.privateSerialRejected(by: OperatingSystemVersion(
			majorVersion: g.majorVersion, minorVersion: g.minorVersion,
			patchVersion: g.patchVersion - 1)))
		// On any host that rejects uarts, the API reason is the version gate carrying that version.
		if VMConfig.privateSerialRejected() {
			let issue = VMConfig.uartUnavailability()
			#expect(issue?.reason == .privateUARTGated)
			#expect(issue?.sinceOSVersion == SerialPortSupport.privateUARTGatedSinceDisplay)
			#expect(issue?.message.contains("com.apple.private.virtualization") == true)
		}
	}

	// Per-OS guest device names (measured conventions: Linux hvc/ttyAMA, FreeBSD ttyV/ttyu,
	// macOS cu.virtio with the bare index-0 name). The macGuest spelling stays an alias.
	@Test func guestDeviceNamesPerOS() {
		#expect(SerialPortKind.console.guestDevice(index: 0, os: .linux) == "hvc0")
		#expect(SerialPortKind.console.guestDevice(index: 2, os: .linux) == "hvc2")
		#expect(SerialPortKind.console.guestDevice(index: 0, os: .freebsd) == "ttyV0.0")
		#expect(SerialPortKind.console.guestDevice(index: 1, os: .freebsd) == "ttyV1.0")
		#expect(SerialPortKind.console.guestDevice(index: 0, os: .macOS) == "cu.virtio")
		#expect(SerialPortKind.console.guestDevice(index: 1, os: .macOS) == "cu.virtio1")
		#expect(SerialPortKind.uart.guestDevice(index: 0, os: .linux) == "ttyAMA0")
		#expect(SerialPortKind.uart.guestDevice(index: 1, os: .freebsd) == "ttyu1")
		#expect(SerialPortKind.uart.guestDevice(index: 0, os: .macOS) == "ttyAMA0")
		#expect(SerialPortKind.console.guestDevice(index: 1, macGuest: true) == "cu.virtio1")
		#expect(SerialPortKind.console.guestDevice(index: 1, macGuest: false) == "hvc1")
	}
}
