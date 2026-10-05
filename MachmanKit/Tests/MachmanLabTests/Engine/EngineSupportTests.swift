//
//  EngineSupportTests.swift
//  MachmanLabTests
//
//  harness — r3-tf's own helpers (Support/TF*), proven without an agent or a guest.
//

import Foundation
import Testing
import MachmanAPI
import MachmanTestSupport

@Suite("Engine support (harness)", .enabled(if: Lab.runs(.harness)))
struct EngineSupportTests {
	@Test("Q18: engine gates read only their opt-in variables")
	func gatesReadOptIns() {
		#expect(!TFGate.localNetwork([:]))
		#expect(!TFGate.localNetwork(["MACHMAN_LAB_LOCAL_NETWORK": "yes"]))
		#expect(!TFGate.localNetwork(["MACHMAN_TF_LOCAL_NETWORK": "1"]))
		#expect(TFGate.localNetwork(["MACHMAN_LAB_LOCAL_NETWORK": "1"]))
		#expect(TFGate.volumes([:]))
		#expect(TFGate.volumes(["MACHMAN_LAB_VOLUMES": "1"]))
		#expect(TFGate.volumes(["MACHMAN_TF_VOLUMES": "0"]))
		#expect(!TFGate.volumes(["MACHMAN_LAB_VOLUMES": "0"]))
		let gate = SerialPortSupport.privateUARTGatedSince
		#expect(TFGate.uartGated(gate))
		#expect(!TFGate.uartGated(OperatingSystemVersion(
			majorVersion: gate.majorVersion, minorVersion: gate.minorVersion,
			patchVersion: gate.patchVersion - 1)))
		#expect(TFGate.uartGated(OperatingSystemVersion(
			majorVersion: gate.majorVersion + 1, minorVersion: 0, patchVersion: 0)))
	}

	@Test("Q18: a config edit keeps unknown keys and replaces the file atomically")
	func configEditKeepsUnknownKeys() throws {
		let dir = TestEnvironment.scratch + "tf-config-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let original = #"{"name":"x","future":{"_0":[1,2]},"cpuCount":1}"#
		try original.write(toFile: TFVM.config(dir: dir), atomically: false, encoding: .utf8)
		let before = try inode(TFVM.config(dir: dir))
		try TFVM.editConfig(dir: dir) { $0["cpuCount"] = 2 }
		let after = try TFVM.readConfig(dir: dir)
		#expect(after["cpuCount"] as? Int == 2)
		#expect(after["name"] as? String == "x")
		let future = try #require(after["future"])
		#expect(try TFVM.canonicalJSON(future) == Data(#"{"_0":[1,2]}"#.utf8))
		#expect(try inode(TFVM.config(dir: dir)) != before)
	}

	@Test("Q18: the process helpers never signal a pid that is not a lab app")
	func processHelpersRefuseOtherPids() async throws {
		let me = getpid()
		#expect(TFProcess.path(of: me) != nil)
		#expect(!TFProcess.isVMHost(me))
		#expect(!TFProcess.isAgent(me))
		#expect(!TFProcess.stop(me))
		#expect(!TFProcess.resume(me))
		#expect(!TFProcess.killLabApp(me))
		#expect(!TFProcess.stop(1))
		let rows = TFProcess.parse("  10     1 /a b c\n   11   10 /d\n12 11 \nx y z\n")
		#expect(rows.map(\.pid) == [10, 11, 12])
		#expect(rows[0].command == "/a b c")
		#expect(TFProcess.descendants(of: 10, in: rows) == [11, 12])
		#expect(TFProcess.footprintBytes() > 0)
	}

	@Test("Q18: the main-actor probe measures a deliberate stall")
	@MainActor
	func mainActorProbeMeasuresStall() async throws {
		let probe = TFMainActorProbe()
		probe.start()
		try await Task.sleep(for: .milliseconds(100))
		usleep(300_000)
		try await Task.sleep(for: .milliseconds(100))
		let gap = probe.stop()
		#expect(gap >= .milliseconds(250))
		#expect(gap < .seconds(5))
	}

	private func inode(_ path: String) throws -> UInt64 {
		let attributes = try FileManager.default.attributesOfItem(atPath: path)
		return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
	}
}
