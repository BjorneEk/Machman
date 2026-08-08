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
				minCPUCount: nil, minMemoryBytes: nil),
			consoleLogPath: "/tmp/console.log")
		let expected = #"{"boot":{"mode":"efi"},"consoleLogPath":"/tmp/console.log","#
			+ #""consoleOpen":false,"cpuCount":4,"created":"2023-11-14T22:13:20Z","#
			+ #""disks":[{"id":"storage:disk","name":"disk","safe":true,"#
			+ #""sizeBytes":10737418240,"type":"storage"}],"lastRan":"2023-11-14T22:15:00Z","#
			+ #""macAddress":"aa:bb:cc:dd:ee:ff","memoryBytes":4294967296,"#
			+ #""mounts":[{"id":"m1","path":"/Users/x/share","safe":true,"tag":"host-share"}],"#
			+ #""name":"Debian","state":"running"}"#
		#expect(try encode(info) == expected)
		#expect(try decode(VMInfo.self, expected) == info)

		// Payloads predating consoleOpen and the safe flags must keep decoding (defaults:
		// false / true).
		let legacy = expected
			.replacingOccurrences(of: #""consoleOpen":false,"#, with: "")
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
				minCPUCount: nil, minMemoryBytes: nil),
			consoleLogPath: nil)
		info.startPolicy = StartPolicy()
		info.safeRun = true
		info.totalRuntimeSeconds = 12.5
		let encoded = try encode(info)
		#expect(encoded.contains(
			#""startPolicy":{"autostart":false,"safe":false,"windowed":true}"#))
		#expect(encoded.contains(#""safeRun":true"#))
		#expect(encoded.contains(#""totalRuntimeSeconds":12.5"#))
		#expect(try decode(VMInfo.self, encoded) == info)
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

	@Test func eventFixtures() throws {
		let cases: [(VMEvent, String)] = [
			(.stateChanged(vm: "Debian", state: .running),
			 #"{"state":"running","type":"stateChanged","vm":"Debian"}"#),
			(.listChanged,
			 #"{"type":"listChanged"}"#),
			(.log(vm: "x", level: .error, message: "boom"),
			 #"{"level":"error","message":"boom","type":"log","vm":"x"}"#),
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
			== StartOptions(openConsole: true, force: false))
		#expect(try encode(StartOptions()) == #"{"force":false,"openConsole":true}"#)
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
	}
}
