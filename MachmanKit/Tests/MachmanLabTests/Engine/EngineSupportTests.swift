//
//  EngineSupportTests.swift
//  MachmanLabTests
//
//  harness — r3-tf's own helpers (Support/TF*), proven without an agent or a guest.
//

import Foundation
import Testing
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
import MachmanClient
import MachmanUI
@testable import MachmanDesktopCore

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

	@Test("Q18: the toast log counts each toast once")
	@MainActor
	func toastLogCountsOnce() async throws {
		let dir = TestEnvironment.scratch + "tf-toasts-\(UUID().uuidString)"
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let desktop = TFDesktop(api: StubMachman.serving([]), dir: dir)
		defer { Task { await desktop.close() } }
		let view = desktop.viewModel
		let connecting = "dev: SSH connecting…"
		view.pushToast(symbol: MachmanSymbols.start, message: connecting, key: "k", spinner: true)
		view.pushToast(symbol: MachmanSymbols.start, message: connecting, key: "k", spinner: true)
		#expect(desktop.toasts.messages == ["dev: SSH connecting…"])
		view.pushToast(symbol: MachmanSymbols.start, message: "dev: SSH ready", key: "k")
		view.pushToast(symbol: MachmanSymbols.start, message: "dev started")
		view.pushToast(symbol: MachmanSymbols.start, message: "dev started")
		#expect(desktop.toasts.messages == [
			"dev: SSH connecting…", "dev: SSH ready", "dev started", "dev started",
		])
		#expect(desktop.toasts.count(equal: "dev started") == 2)
		#expect(desktop.toasts.entries.first?.spinner == true)
	}

	@Test("Q18: lab ssh arguments put the host-quiet options before the product's")
	func sshArgumentsHostQuietFirst() throws {
		let ssh = SSHInfo(
			guestUser: "lab", guestHostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQ tf",
			alias: TFSSHTarget.alias, identityFilePath: "/tmp/mml.ab12/k/id_ed25519",
			knownHostsPath: "/tmp/mml.ab12/k/known_hosts", address: "127.0.0.1")
		let vm = TFSSHTarget.syntheticVM(ssh)
		let argv = try #require(TFSSHTarget.arguments(for: vm, port: 2222))
		#expect(Array(argv.prefix(TFSSH.hostQuietPrefix.count)) == TFSSH.hostQuietPrefix)
		#expect(argv.prefix(2) == ["-F", "/dev/null"])
		#expect(argv.last == "lab@127.0.0.1")
		let product = Array(argv.dropFirst(TFSSH.hostQuietPrefix.count + 2))
		#expect(product == SSHCommand.arguments(for: vm))
		#expect(argv.contains("IdentityAgent=none"))
		#expect(argv.contains("GlobalKnownHostsFile=/dev/null"))
		#expect(argv.contains(#"UserKnownHostsFile="/tmp/mml.ab12/k/known_hosts""#))
		#expect(!argv.contains { $0.contains(NSHomeDirectory() + "/.ssh") })
	}

	@Test("Q18: a patched build copy changes only the two version keys")
	func patchedCopyChangesVersionsOnly() {
		let plist: [String: Any] = [
			"CFBundleIdentifier": "com.gustaffranzen.Machman.dev.agent",
			"CFBundleShortVersionString": "1.0.12", "CFBundleVersion": "1.0.12",
			"LSUIElement": true,
		]
		let patched = TFBuilds.patchPlist(plist, version: "1.0.11")
		#expect(patched["CFBundleShortVersionString"] as? String == "1.0.11")
		#expect(patched["CFBundleVersion"] as? String == "1.0.11")
		#expect(patched["CFBundleIdentifier"] as? String == "com.gustaffranzen.Machman.dev.agent")
		#expect(patched["LSUIElement"] as? Bool == true)
		#expect(patched.count == plist.count)
		#expect(TFBuilds.olderVersion(than: "1.0.12") == "1.0.11")
		#expect(TFBuilds.olderVersion(than: "1.2.0") == "1.1.99")
		#expect(TFBuilds.newerVersion(than: "1.0.12") == "1.0.99")
		#expect(MachmanVersion.isOlder(TFBuilds.olderVersion(than: "1.0.12"), than: "1.0.12"))
		#expect(MachmanVersion.isOlder("1.0.12", than: TFBuilds.newerVersion(than: "1.0.12")))
	}

	@Test("Q18: lab volumes are created and mounted only under the run sandbox")
	func volumesStayInSandbox() {
		let root = "/tmp/mml.ab12"
		for format in TFVolume.Format.allCases {
			let lines = TFVolume.commandLines(format, gib: 2, name: "v", root: root)
			#expect(lines.image == root + "/tf-volumes/v.sparsebundle")
			#expect(lines.mountPoint == root + "/tf-volumes/v.mnt")
			#expect(lines.create.contains(format.rawValue))
			#expect(lines.create.last == lines.image)
			#expect(lines.attach.contains("-nobrowse"))
			#expect(lines.attach.contains("-noautoopen"))
			let mount = lines.attach.firstIndex(of: "-mountpoint").map { lines.attach[$0 + 1] }
			#expect(mount == lines.mountPoint)
			#expect(lines.attach.last == lines.image)
		}
	}

	private func inode(_ path: String) throws -> UInt64 {
		let attributes = try FileManager.default.attributesOfItem(atPath: path)
		return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
	}
}
