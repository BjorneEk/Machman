import Testing
import Foundation
import MachmanAPI

// Golden fixtures for the API wire format. These strings ARE the contract: once phase 2 puts
// JSON-RPC on the socket (and non-Swift clients appear), changing any of them is a breaking
// API change — extend with new optional fields instead.
struct WireFixtureTests {
	private func encode<T: Encodable>(_ value: T) throws -> String {
		String(decoding: try MachmanWire.encoder().encode(value), as: UTF8.self)
	}

	private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
		try MachmanWire.decoder().decode(type, from: Data(json.utf8))
	}

	@Test func vmInfoFixture() throws {
		let info = VMInfo(
			name: "Debian", state: .running,
			created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: Date(timeIntervalSince1970: 1_700_000_100),
			cpuCount: 4, memoryBytes: 4_294_967_296,
			macAddress: "aa:bb:cc:dd:ee:ff",
			disks: [DiskInfo(
				id: "storage:disk", type: .storage, name: "disk", path: nil,
				sizeBytes: 10_737_418_240)],
			mounts: [MountInfo(id: "m1", path: "/Users/x/share", tag: "host-share")],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
		let expected = #"{"boot":{"mode":"efi"},"cpuCount":4,"#
			+ #""created":"2023-11-14T22:13:20Z","#
			+ #""disks":[{"id":"storage:disk","name":"disk","safe":true,"#
			+ #""sizeBytes":10737418240,"type":"storage"}],"lastRan":"2023-11-14T22:15:00Z","#
			+ #""macAddress":"aa:bb:cc:dd:ee:ff","memoryBytes":4294967296,"#
			+ #""mounts":[{"id":"m1","path":"/Users/x/share","safe":true,"tag":"host-share"}],"#
			+ #""name":"Debian","state":"running","windowOpen":false}"#
		#expect(try encode(info) == expected)
		#expect(try decode(VMInfo.self, expected) == info)

		// Payloads predating windowOpen and the safe flags must keep decoding (defaults:
		// false / true).
		let legacy = expected
			.replacingOccurrences(of: #","windowOpen":false"#, with: "")
			.replacingOccurrences(of: #""safe":true,"#, with: "")
		#expect(try decode(VMInfo.self, legacy) == info)
	}

	@Test func vmInfoOptionalFieldsRoundTrip() throws {
		var info = VMInfo(
			name: "Debian", state: .stopped,
			created: Date(timeIntervalSince1970: 1_700_000_000), lastRan: nil,
			cpuCount: 2, memoryBytes: 1024, macAddress: nil, disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
		info.startPolicy = StartPolicy()
		info.safeRun = true
		info.totalRuntimeSeconds = 12.5
		info.consolePorts = [SerialPortInfo(
			kind: .console, index: 0, guestDevice: "hvc0", logging: SerialLogConfig())]
		info.uartPorts = [SerialPortInfo(
			kind: .uart, index: 0, guestDevice: "ttyAMA0", logging: SerialLogConfig())]
		let encoded = try encode(info)
		#expect(encoded.contains(
			#""startPolicy":{"autostart":false,"safe":false,"windowed":true}"#))
		#expect(encoded.contains(#""safeRun":true"#))
		#expect(encoded.contains(#""totalRuntimeSeconds":12.5"#))
		#expect(encoded.contains(#""consolePorts":[{"guestDevice":"hvc0","#))
		#expect(encoded.contains(#""uartPorts":[{"guestDevice":"ttyAMA0","#))
		#expect(try decode(VMInfo.self, encoded) == info)
	}

	@Test func serialPortInfoFixture() throws {
		let port = SerialPortInfo(
			kind: .uart, index: 1, guestDevice: "ttyAMA1",
			logging: SerialLogConfig(mode: .continuous, maxBytes: 4096),
			socketPath: "/tmp/tty.sock", logPath: "/vm/serial-uart1.log",
			mmioBase: "0x20020000", irq: 33)
		let expected = #"{"guestDevice":"ttyAMA1","index":1,"irq":33,"kind":"uart","#
			+ #""logPath":"/vm/serial-uart1.log","logging":{"maxBytes":4096,"mode":"continuous"},"#
			+ #""mmioBase":"0x20020000","socketPath":"/tmp/tty.sock"}"#
		#expect(try encode(port) == expected)
		#expect(try decode(SerialPortInfo.self, expected) == port)

		// A minimal port omits every nil and carries default logging.
		let minimal = SerialPortInfo(
			kind: .console, index: 0, guestDevice: "hvc0", logging: SerialLogConfig())
		let minExpected =
			#"{"guestDevice":"hvc0","index":0,"kind":"console","logging":{"mode":"resetOnBoot"}}"#
		#expect(try encode(minimal) == minExpected)
		#expect(try decode(SerialPortInfo.self, minExpected) == minimal)

		// The compacted guest index rides along when served (additive: the minimal case
		// above proves absence still decodes — older daemons never send it).
		let indexed = SerialPortInfo(
			kind: .console, index: 2, guestDevice: "hvc1", logging: SerialLogConfig(),
			enabled: true, guestIndex: 1)
		let indexedExpected =
			#"{"enabled":true,"guestDevice":"hvc1","guestIndex":1,"index":2,"kind":"console","#
			+ #""logging":{"mode":"resetOnBoot"}}"#
		#expect(try encode(indexed) == indexedExpected)
		#expect(try decode(SerialPortInfo.self, indexedExpected) == indexed)

		// A uart the host can't attach carries its reason; nil socket/mmio stay omitted.
		let gated = SerialPortInfo(
			kind: .uart, index: 0, guestDevice: "ttyAMA0", logging: SerialLogConfig(),
			unavailable: SerialPortUnavailability(
				reason: .privateUARTGated, message: "UART unavailable on this host.",
				sinceOSVersion: "26.6.1"))
		let gatedExpected =
			#"{"guestDevice":"ttyAMA0","index":0,"kind":"uart","logging":{"mode":"resetOnBoot"},"#
			+ #""unavailable":{"message":"UART unavailable on this host.","#
			+ #""reason":"privateUARTGated","sinceOSVersion":"26.6.1"}}"#
		#expect(try encode(gated) == gatedExpected)
		#expect(try decode(SerialPortInfo.self, gatedExpected) == gated)

		// An unknown future reason degrades to .unknown rather than failing the decode.
		let future = #"{"message":"m","reason":"newKind"}"#
		#expect(try decode(SerialPortUnavailability.self, future).reason == .unknown)
	}

	@Test func bootInfoMacOSFixture() throws {
		let boot = BootInfo(
			mode: .macOS, kernel: nil,
			macInstallState: MacInstallState(kind: .failed, message: "VZError 10006"),
			minCPUCount: 4, minMemoryBytes: 4_294_967_296)
		let expected = #"{"macInstallState":{"kind":"failed","message":"VZError 10006"},"#
			+ #""minCPUCount":4,"minMemoryBytes":4294967296,"mode":"macOS"}"#
		#expect(try encode(boot) == expected)
		#expect(try decode(BootInfo.self, expected) == boot)
		#expect(!boot.macInstalled)
	}

	@Test func bootInfoOwnedKernelsRoundTrip() throws {
		let path = "/vm/k/kernels/kernel/janus/vmlinuz"
		let boot = BootInfo(
			mode: .linuxKernel,
			kernel: KernelSettings(kernelPath: path, initrdPath: nil, commandLine: "console=hvc0"),
			macInstallState: nil, minCPUCount: nil, minMemoryBytes: nil,
			ownedKernels: [OwnedKernelFile(
				role: .kernel, tag: "janus", fileName: "vmlinuz", path: path)])
		let encoded = try encode(boot)
		#expect(encoded.contains(
			#""ownedKernels":[{"fileName":"vmlinuz","path":"\#(path)","role":"kernel","tag":"janus"}]"#))
		#expect(try decode(BootInfo.self, encoded) == boot)
	}

	@Test func eventFixtures() throws {
		let cases: [(VMEvent, String)] = [
			(.stateChanged(vm: "Debian", state: .running),
			 #"{"state":"running","type":"stateChanged","vm":"Debian"}"#),
			(.listChanged,
			 #"{"type":"listChanged"}"#),
			(.copyProgress(vm: "Debian copy", copiedBytes: 512, totalBytes: 1024),
			 #"{"copiedBytes":512,"totalBytes":1024,"type":"copyProgress","vm":"Debian copy"}"#),
			(.log(vm: "x", level: .error, message: "boom"),
			 #"{"level":"error","message":"boom","type":"log","vm":"x"}"#),
			(.sshChanged(vm: "Debian"),
			 #"{"type":"sshChanged","vm":"Debian"}"#),
			(.installPhaseChanged(vm: "macOS", phase: InstallPhase(
				kind: .downloading, version: "15.5", build: "24F74",
				progress: ProgressInfo(fraction: 0.5, completedBytes: 100, totalBytes: 200),
				downloadStartedAt: Date(timeIntervalSince1970: 1_700_000_000))),
			 #"{"phase":{"build":"24F74","downloadStartedAt":"2023-11-14T22:13:20Z","#
			 + #""kind":"downloading","progress":{"completedBytes":100,"fraction":0.5,"#
			 + #""totalBytes":200},"version":"15.5"},"type":"installPhaseChanged","vm":"macOS"}"#),
		]
		for (event, expected) in cases {
			#expect(try encode(event) == expected)
			#expect(try decode(VMEvent.self, expected) == event)
		}
	}

	@Test func unknownValuesDecodeTolerantly() throws {
		#expect(try decode(VMEvent.self, #"{"type":"futureThing","x":1}"#)
			== .unknown(type: "futureThing"))
		#expect(try decode([VMState].self, #"["hibernating"]"#) == [.unknown])
		#expect(try decode(MachmanError.self, #"{"code":"weird","message":"m"}"#).code
			== .internalError)
		// macConflict's raw value is wire contract from 3.5 on.
		#expect(try decode(MachmanError.self, #"{"code":"macConflict","message":"m"}"#).code
			== .macConflict)
	}

	@Test func startOptionsDefaultsOnDecode() throws {
		#expect(try decode(StartOptions.self, "{}")
			== StartOptions(openWindow: true, force: false, safe: false))
		#expect(try encode(StartOptions())
			== #"{"force":false,"openWindow":true,"safe":false}"#)
	}

	@Test func startPolicyDefaultsOnDecode() throws {
		#expect(try decode(StartPolicy.self, "{}") == StartPolicy())
		#expect(try encode(StartPolicy())
			== #"{"autostart":false,"safe":false,"windowed":true}"#)
	}

	@Test func requestShapes() throws {
		#expect(try encode(NewDisk.storage(name: "disk", sizeBytes: 1024))
			== #"{"name":"disk","sizeBytes":1024,"type":"storage"}"#)
		#expect(try encode(NewDisk.iso(path: "/isos/debian.iso"))
			== #"{"path":"/isos/debian.iso","type":"iso"}"#)
		#expect(try encode(InstallSource.ipsw("/tmp/a.ipsw"))
			== #"{"kind":"ipsw","path":"/tmp/a.ipsw"}"#)
		#expect(try encode(StopMode.soft) == #""soft""#)
		// Dict params encode deterministically (sortedKeys); absent dicts are omitted.
		#expect(try encode(RPCParams.SetSafety(
			name: "Debian", disks: ["b:2": true, "a:1": false], mounts: nil))
			== #"{"disks":{"a:1":false,"b:2":true},"name":"Debian"}"#)
		// Copy: every optional omitted when nil.
		#expect(try encode(RPCParams.Copy(
			name: "Debian", newName: nil, diskIDs: nil, regenerateMAC: nil))
			== #"{"name":"Debian"}"#)
		#expect(try encode(RPCParams.Copy(
			name: "Debian", newName: "Deb2", diskIDs: ["storage:disk"], regenerateMAC: false))
			== #"{"diskIDs":["storage:disk"],"name":"Debian","newName":"Deb2","#
			+ #""regenerateMAC":false}"#)
		// Rename params serve vm.rename AND vm.safeSave — one shape, method discriminates.
		#expect(try encode(RPCParams.Rename(name: "Debian", newName: "Debian kept"))
			== #"{"name":"Debian","newName":"Debian kept"}"#)
		#expect(try encode(RPCParams.ImportDisk(name: "Debian", path: "/imgs/a.raw"))
			== #"{"name":"Debian","path":"/imgs/a.raw"}"#)
		#expect(try encode(RPCParams.PromoteKernel(
			name: "Debian", role: .kernel, sourcePath: "/tmp/vmlinuz", tag: "janus"))
			== #"{"name":"Debian","role":"kernel","sourcePath":"/tmp/vmlinuz","tag":"janus"}"#)
		#expect(try encode(RPCParams.DeleteKernel(name: "Debian", path: "/k/janus/vmlinuz"))
			== #"{"name":"Debian","path":"/k/janus/vmlinuz"}"#)
		// DiskInfo.owned is nil-omitted (old-daemon tolerance) and pins when set.
		#expect(try encode(DiskInfo(
			id: "iso:x", type: .iso, name: nil, path: "/x.iso", sizeBytes: nil,
			safe: true, owned: false))
			== #"{"id":"iso:x","owned":false,"path":"/x.iso","safe":true,"type":"iso"}"#)
	}

	// MARK: - 1.0.4: guest devices, enabled flags, operations

	@Test func deviceInfoFixture() throws {
		let graphics = DeviceInfo(
			kind: .graphics, displayWidthPixels: 2560, displayHeightPixels: 1440,
			displayPixelsPerInch: 80)
		let expected = #"{"displayHeightPixels":1440,"displayPixelsPerInch":80,"#
			+ #""displayWidthPixels":2560,"enabled":true,"kind":"graphics"}"#
		#expect(try encode(graphics) == expected)
		#expect(try decode(DeviceInfo.self, expected) == graphics)

		// A minimal device omits every nil setting.
		#expect(try encode(DeviceInfo(kind: .network))
			== #"{"enabled":true,"kind":"network"}"#)
		#expect(try encode(DeviceInfo(kind: .clipboard, sharesClipboard: false))
			== #"{"enabled":true,"kind":"clipboard","sharesClipboard":false}"#)

		// A host-gated device carries its reason (the serial-port shape, generalized).
		let rosetta = DeviceInfo(
			kind: .rosetta,
			unavailable: UnavailabilityInfo(
				reason: .notInstalled, message: "Rosetta is not installed."))
		#expect(try encode(rosetta)
			== #"{"enabled":true,"kind":"rosetta","unavailable":"#
			+ #"{"message":"Rosetta is not installed.","reason":"notInstalled"}}"#)

		// Unknown future kinds degrade to .unknown; absent enabled defaults to true.
		#expect(try decode(DeviceInfo.self, #"{"enabled":true,"kind":"quantum"}"#).kind
			== .unknown)
		let legacy = try decode(DeviceInfo.self, #"{"kind":"entropy"}"#)
		#expect(legacy.kind == .entropy)
		#expect(legacy.enabled)
	}

	@Test func vmInfoDevicesRoundTrip() throws {
		var info = VMInfo(
			name: "Debian", state: .stopped,
			created: Date(timeIntervalSince1970: 1_700_000_000), lastRan: nil,
			cpuCount: 2, memoryBytes: 1024, macAddress: nil, disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
		info.devices = [DeviceInfo(kind: .keyboard), DeviceInfo(kind: .graphics)]
		info.nestedVirtualization = true
		let encoded = try encode(info)
		#expect(encoded.contains(
			#""devices":[{"enabled":true,"kind":"keyboard"},{"enabled":true,"kind":"graphics"}]"#))
		#expect(encoded.contains(#""nestedVirtualization":true"#))
		#expect(try decode(VMInfo.self, encoded) == info)

		// Payloads from daemons predating devices still decode; the fields read nil.
		let legacy = encoded
			.replacingOccurrences(
				of: #""devices":[{"enabled":true,"kind":"keyboard"},"#
					+ #"{"enabled":true,"kind":"graphics"}],"#,
				with: "")
			.replacingOccurrences(of: #","nestedVirtualization":true"#, with: "")
		let decoded = try decode(VMInfo.self, legacy)
		#expect(decoded.devices == nil)
		#expect(decoded.nestedVirtualization == nil)
	}

	@Test func enabledFlagsTriState() throws {
		// enabled pins when set and is omitted when nil (all three entity kinds).
		#expect(try encode(DiskInfo(
			id: "d", type: .storage, name: "disk", path: nil, sizeBytes: nil,
			enabled: false))
			== #"{"enabled":false,"id":"d","name":"disk","safe":true,"type":"storage"}"#)
		#expect(try encode(MountInfo(id: "m", path: "/x", tag: "t", enabled: false))
			== #"{"enabled":false,"id":"m","path":"/x","safe":true,"tag":"t"}"#)
		#expect(try encode(SerialPortInfo(
			kind: .console, index: 0, guestDevice: "hvc0", logging: SerialLogConfig(),
			enabled: false))
			== #"{"enabled":false,"guestDevice":"hvc0","index":0,"kind":"console","#
			+ #""logging":{"mode":"resetOnBoot"}}"#)
		// Absent = enabled (old daemons): nil on the field, true through isEnabled.
		let legacyDisk = try decode(DiskInfo.self,
			#"{"id":"d","safe":true,"type":"storage"}"#)
		#expect(legacyDisk.enabled == nil)
		#expect(legacyDisk.isEnabled)
	}

	@Test func kernelOverrideRoundTrip() throws {
		let file = OwnedKernelFile(
			role: .kernel, tag: "janus", fileName: "vmlinuz", path: "/k/janus/vmlinuz",
			overrideCommandLine: "console=hvc0 quiet", overrideEnabled: true)
		let encoded = try encode(file)
		#expect(encoded.contains(#""overrideCommandLine":"console=hvc0 quiet""#))
		#expect(encoded.contains(#""overrideEnabled":true"#))
		#expect(try decode(OwnedKernelFile.self, encoded) == file)
		// Legacy payloads without the override fields keep decoding (nil).
		let legacy = try decode(OwnedKernelFile.self,
			#"{"fileName":"vmlinuz","path":"/k/janus/vmlinuz","role":"kernel","tag":"janus"}"#)
		#expect(legacy.overrideCommandLine == nil)
		#expect(legacy.overrideEnabled == nil)
	}

	@Test func operationFixtures() throws {
		let op = OperationInfo(
			id: "op-1", kind: OperationInfo.Kind.copyVM, vm: "Debian",
			label: "Copying system.img", fraction: 0.25, completedBytes: 256,
			totalBytes: 1024, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
		let expected = #"{"completedBytes":256,"fraction":0.25,"id":"op-1","kind":"copyVM","#
			+ #""label":"Copying system.img","startedAt":"2023-11-14T22:13:20Z","#
			+ #""state":"running","totalBytes":1024,"vm":"Debian"}"#
		#expect(try encode(op) == expected)
		#expect(try decode(OperationInfo.self, expected) == op)
		#expect(!op.isFinished)

		// The event wraps the operation under "op"; old clients see .unknown and ignore it.
		let minimal = OperationInfo(
			id: "op-2", kind: OperationInfo.Kind.rosettaInstall, label: "Installing Rosetta",
			startedAt: Date(timeIntervalSince1970: 1_700_000_000))
		let event = VMEvent.operationChanged(op: minimal)
		let eventExpected = #"{"op":{"id":"op-2","kind":"rosettaInstall","#
			+ #""label":"Installing Rosetta","startedAt":"2023-11-14T22:13:20Z","#
			+ #""state":"running"},"type":"operationChanged"}"#
		#expect(try encode(event) == eventExpected)
		#expect(try decode(VMEvent.self, eventExpected) == event)

		// Unknown kinds/states are open-set strings: they survive untouched.
		let future = try decode(OperationInfo.self, expected
			.replacingOccurrences(of: #""kind":"copyVM""#, with: #""kind":"teleport""#))
		#expect(future.kind == "teleport")
	}

	@Test func hostCapabilitiesCompat() throws {
		// Old-daemon payloads (base fields only) keep decoding; additions read nil.
		let legacy = try decode(HostCapabilities.self,
			#"{"freeDiskBytes":1,"maxCPUCount":8,"maxMemoryBytes":100,"minMemoryBytes":10}"#)
		#expect(legacy.rosettaAvailability == nil)
		#expect(legacy.uartUnavailable == nil)
		#expect(legacy.nestedVirtualizationSupported == nil)

		var caps = HostCapabilities(
			maxCPUCount: 8, minMemoryBytes: 10, maxMemoryBytes: 100, freeDiskBytes: 1)
		caps.nestedVirtualizationSupported = true
		caps.rosettaAvailability = RosettaAvailability.installed
		caps.hostDisplayWidthPixels = 3024
		caps.hostDisplayHeightPixels = 1964
		caps.maxSerialPorts = 10
		caps.uartUnavailable = UnavailabilityInfo(
			reason: .privateUARTGated, message: "UART unavailable.", sinceOSVersion: "26.6.1")
		let encoded = try encode(caps)
		#expect(encoded.contains(#""nestedVirtualizationSupported":true"#))
		#expect(encoded.contains(#""rosettaAvailability":"installed""#))
		#expect(encoded.contains(#""hostDisplayWidthPixels":3024"#))
		#expect(encoded.contains(#""maxSerialPorts":10"#))
		#expect(encoded.contains(#""uartUnavailable":{"message":"UART unavailable.","#))
		#expect(try decode(HostCapabilities.self, encoded) == caps)
	}

	@Test func impliedDevices() throws {
		let mac = ImpliedDevices.kinds(macGuest: true)
		#expect(mac.contains(.trackpad))
		#expect(!mac.contains(.clipboard))
		let linux = ImpliedDevices.kinds(macGuest: false)
		#expect(linux.contains(.clipboard))
		#expect(!linux.contains(.trackpad))
		#expect(!DeviceKind.allKinds.contains(.unknown))
		// The login installer (additive kind): raw value pinned; never implied.
		#expect(DeviceKind(rawValue: "consoleLoginInstaller") == .consoleLoginInstaller)
		#expect(DeviceKind.allKinds.contains(.consoleLoginInstaller))
		#expect(!mac.contains(.consoleLoginInstaller))
		// The ssh installer (1.0.5 additive kind): raw value pinned; never implied.
		#expect(DeviceKind(rawValue: "sshInstaller") == .sshInstaller)
		#expect(DeviceKind.allKinds.contains(.sshInstaller))
		#expect(!mac.contains(.sshInstaller))
		#expect(!linux.contains(.sshInstaller))
		// The unified installer (1.0.7 additive kind): raw value pinned; never implied.
		#expect(DeviceKind(rawValue: "guestSetup") == .guestSetup)
		#expect(DeviceKind.allKinds.contains(.guestSetup))
		#expect(!mac.contains(.guestSetup))
		#expect(!linux.contains(.guestSetup))
	}

	@Test func newRequestShapes() throws {
		#expect(try encode(RPCParams.Create(template: nil)) == "{}")
		#expect(try encode(RPCParams.Create(template: "mac")) == #"{"template":"mac"}"#)
		#expect(try encode(RPCParams.DeviceMutation(name: "Debian", kind: .entropy))
			== #"{"kind":"entropy","name":"Debian"}"#)
		#expect(try encode(RPCParams.DeviceUpdate(
			name: "Debian", device: DeviceInfo(kind: .graphics, enabled: false)))
			== #"{"device":{"enabled":false,"kind":"graphics"},"name":"Debian"}"#)
		#expect(try encode(RPCParams.SetEnabled(
			name: "Debian", disks: ["a": false], console: ["0": true]))
			== #"{"console":{"0":true},"disks":{"a":false},"name":"Debian"}"#)
		#expect(try encode(RPCParams.KernelOverride(
			name: "Debian", path: "/k", commandLine: "quiet", overrideEnabled: true))
			== #"{"commandLine":"quiet","name":"Debian","overrideEnabled":true,"path":"/k"}"#)
		#expect(try encode(RPCParams.ResizeDisk(
			name: "Debian", diskID: "d", sizeBytes: 2048))
			== #"{"diskID":"d","name":"Debian","sizeBytes":2048}"#)
		#expect(try encode(RPCParams.RenameDisk(
			name: "Debian", diskID: "storage:disk", newName: "root"))
			== #"{"diskID":"storage:disk","name":"Debian","newName":"root"}"#)
		#expect(try encode(RPCParams.SetMountTag(
			name: "Debian", mountID: "m1", tag: "shared"))
			== #"{"mountID":"m1","name":"Debian","tag":"shared"}"#)
		#expect(try encode(RPCParams.SetMountKind(
			name: "Debian", mountID: "m1", kind: MountKind.sshfs))
			== #"{"kind":"sshfs","mountID":"m1","name":"Debian"}"#)
		// AddMount without a kind stays byte-identical to the 1.0.6 shape.
		#expect(try encode(RPCParams.AddMount(name: "Debian", path: "/x", tag: "t"))
			== #"{"name":"Debian","path":"/x","tag":"t"}"#)
		#expect(try encode(RPCParams.AddMount(
			name: "Debian", path: "/x", tag: "t", kind: MountKind.sshfs))
			== #"{"kind":"sshfs","name":"Debian","path":"/x","tag":"t"}"#)
		#expect(try encode(RPCParams.RenameKernel(
			name: "Debian", path: "/k/kernel/old/Image", tag: "new"))
			== #"{"name":"Debian","path":"/k/kernel/old/Image","tag":"new"}"#)
		#expect(try encode(RPCParams.CancelOperation(id: "op-1")) == #"{"id":"op-1"}"#)
		#expect(try encode(RPCParams.SSHSet(
			name: "Debian", integrationEnabled: true, reverseApproved: nil))
			== #"{"integrationEnabled":true,"name":"Debian"}"#)
		#expect(try encode(RPCParams.SSHSet(
			name: "Debian", integrationEnabled: nil, reverseApproved: nil))
			== #"{"name":"Debian"}"#)
	}

	@Test func sshInfoFixtures() throws {
		// Minimal shape: only the non-optional state encodes.
		#expect(try encode(SSHInfo()) == #"{"reverseState":"none"}"#)
		let full = SSHInfo(
			configured: true,
			guestUser: "admin", guestHostname: "debs", guestOS: "debian",
			guestOSVersion: "13", guestHostKey: "ssh-ed25519 HHHH host",
			reverseState: .pending, reversePublicKey: "ssh-ed25519 AAAA guest",
			integrationEnabled: true,
			lastReportAt: Date(timeIntervalSince1970: 1_700_000_000),
			lastRunStatus: "partial", lastRunNote: "sshfs install failed",
			lastTransport: "virtiofs", scriptVersion: 2,
			sshfsAvailable: true, sshfsMountReady: false, sshfsMountRoot: "/mnt/machman",
			alias: "Debian.machman",
			identityFilePath: "/vms/Debian/ssh/id_ed25519",
			knownHostsPath: "/vms/Debian/ssh/known_hosts",
			setupSharePath: "/vms/Debian/share", hostUser: "gustaf",
			address: "192.168.64.5", addressSource: "dhcp",
			hostAddressForGuest: "192.168.64.1",
			reachability: .ready, reachabilityDetail: nil,
			readySince: Date(timeIntervalSince1970: 1_700_000_060))
		let expected = #"{"address":"192.168.64.5","addressSource":"dhcp","#
			+ #""alias":"Debian.machman","configured":true,"#
			+ #""guestHostKey":"ssh-ed25519 HHHH host","#
			+ #""guestHostname":"debs","guestOS":"debian","guestOSVersion":"13","#
			+ #""guestUser":"admin","hostAddressForGuest":"192.168.64.1","#
			+ #""hostUser":"gustaf","#
			+ #""identityFilePath":"/vms/Debian/ssh/id_ed25519","integrationEnabled":true,"#
			+ #""knownHostsPath":"/vms/Debian/ssh/known_hosts","#
			+ #""lastReportAt":"2023-11-14T22:13:20Z","lastRunNote":"sshfs install failed","#
			+ #""lastRunStatus":"partial","lastTransport":"virtiofs","#
			+ #""reachability":"ready","readySince":"2023-11-14T22:14:20Z","#
			+ #""reversePublicKey":"ssh-ed25519 AAAA guest","reverseState":"pending","#
			+ #""scriptVersion":2,"setupSharePath":"/vms/Debian/share","#
			+ #""sshfsAvailable":true,"sshfsMountReady":false,"#
			+ #""sshfsMountRoot":"/mnt/machman"}"#
		#expect(try encode(full) == expected)
		#expect(try decode(SSHInfo.self, expected) == full)
		// Unknown future reverse states and reachabilities degrade, never fail.
		#expect(try decode(SSHInfo.self, #"{"reverseState":"futureThing"}"#).reverseState
			== .unknown)
		#expect(try decode(SSHInfo.self, #"{"reachability":"futureThing"}"#).reachability
			== .unknown)
		// A 1.0.5 payload still decodes: the new keys are simply absent.
		let old = #"{"guestUser":"admin","reverseState":"none"}"#
		#expect(try decode(SSHInfo.self, old).alias == nil)
	}

	@Test func vmInfoSSHRoundTrip() throws {
		var info = VMInfo(
			name: "Debian", state: .stopped,
			created: Date(timeIntervalSince1970: 1_700_000_000), lastRan: nil,
			cpuCount: 2, memoryBytes: 1024, macAddress: nil, disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
		info.ssh = SSHInfo(guestUser: "admin")
		let encoded = try encode(info)
		#expect(encoded.contains(#""ssh":{"guestUser":"admin","reverseState":"none"}"#))
		#expect(try decode(VMInfo.self, encoded) == info)
		// Payloads from daemons predating ssh still decode; the field reads nil.
		let legacy = encoded.replacingOccurrences(
			of: #","ssh":{"guestUser":"admin","reverseState":"none"}"#, with: "")
		#expect(try decode(VMInfo.self, legacy).ssh == nil)
	}

	@Test func setupChangedEventFixture() throws {
		let event = VMEvent.setupChanged(vm: "Debian")
		let expected = #"{"type":"setupChanged","vm":"Debian"}"#
		#expect(try encode(event) == expected)
		#expect(try decode(VMEvent.self, expected) == event)
		// Clients predating it degrade to .unknown, never fail the stream.
		#expect(try decode(VMEvent.self, #"{"type":"somethingNewer","vm":"x"}"#)
			== .unknown(type: "somethingNewer"))
	}

	@Test func guestSetupInfoFixtures() throws {
		// Empty shape encodes to nothing at all — every field is optional.
		#expect(try encode(GuestSetupInfo()) == "{}")
		let full = GuestSetupInfo(
			installed: true,
			guestOS: "debian", guestOSFamily: "debian", guestOSVersion: "13",
			guestInit: "systemd",
			lastReportAt: Date(timeIntervalSince1970: 1_700_000_000),
			scriptVersion: 3, currentScriptVersion: 3,
			lastRunStatus: "partial", lastRunNote: "one step failed",
			lastTransport: "virtiofs",
			errors: [GuestSetupError(step: "sshd", message: "could not enable the service")],
			features: [GuestFeatureInfo(
				id: GuestFeature.ssh, available: true, configured: true, detail: "gustaf")],
			consoles: [GuestConsoleInfo(device: "hvc0", login: "active", kernelConsole: true)],
			automounts: [GuestAutomountInfo(
				kind: MountKind.virtiofs, target: "host-share", path: "/mnt/machman/share")])
		let encoded = try encode(full)
		#expect(encoded.contains(#""installed":true"#))
		#expect(encoded.contains(#""guestInit":"systemd""#))
		#expect(encoded.contains(#""scriptVersion":3"#))
		#expect(encoded.contains(
			#""errors":[{"message":"could not enable the service","step":"sshd"}]"#))
		#expect(encoded.contains(
			#""features":[{"available":true,"configured":true,"detail":"gustaf","id":"ssh"}]"#))
		#expect(encoded.contains(
			#""consoles":[{"device":"hvc0","kernelConsole":true,"login":"active"}]"#))
		// external (a login configured outside Machman) pins when set, omits when nil.
		#expect(try encode(GuestConsoleInfo(
			device: "hvc1", login: "configured", external: true))
			== #"{"device":"hvc1","external":true,"login":"configured"}"#)
		#expect(encoded.contains(#""automounts":[{"kind":"virtiofs","#
			+ #""path":"/mnt/machman/share","target":"host-share"}]"#))
		#expect(try decode(GuestSetupInfo.self, encoded) == full)
		// A feature with only an id still decodes (defaults false), and unknown feature
		// ids are plain strings — they survive untouched.
		let sparse = try decode(GuestFeatureInfo.self, #"{"id":"futureFeature"}"#)
		#expect(sparse.id == "futureFeature")
		#expect(!sparse.available)
		#expect(!sparse.configured)
	}

	@Test func vmInfoSetupRoundTrip() throws {
		var info = VMInfo(
			name: "Debian", state: .stopped,
			created: Date(timeIntervalSince1970: 1_700_000_000), lastRan: nil,
			cpuCount: 2, memoryBytes: 1024, macAddress: nil, disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
		info.setup = GuestSetupInfo(installed: true, guestOS: "debian")
		let encoded = try encode(info)
		#expect(encoded.contains(#""setup":{"guestOS":"debian","installed":true}"#))
		#expect(try decode(VMInfo.self, encoded) == info)
		// Payloads from daemons predating setup still decode; the field reads nil.
		let legacy = encoded.replacingOccurrences(
			of: #","setup":{"guestOS":"debian","installed":true}"#, with: "")
		#expect(try decode(VMInfo.self, legacy).setup == nil)
	}

	@Test func mountKindRoundTrip() throws {
		// kind/automounted pin when set and are omitted when nil.
		#expect(try encode(MountInfo(
			id: "m", path: "/x", tag: "docs", kind: MountKind.sshfs, automounted: true))
			== #"{"automounted":true,"id":"m","kind":"sshfs","path":"/x","#
			+ #""safe":true,"tag":"docs"}"#)
		// Legacy payloads (no kind) decode as virtiofs through effectiveKind.
		let legacy = try decode(MountInfo.self, #"{"id":"m","path":"/x","tag":"docs"}"#)
		#expect(legacy.kind == nil)
		#expect(legacy.effectiveKind == MountKind.virtiofs)
		#expect(legacy.automounted == nil)
	}
}
