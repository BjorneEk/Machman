//
//  EngineLongWorkTests.swift
//  MachmanLabTests
//
//  L2 — what the agent refuses, keeps and asks while a long copy into or out of a VM's
//  folder runs (E33/D20, E34, E45, E46, E47). The library is on an HFS+ disk image (no
//  clonefile: every copy is a real byte copy), the source a non-sparse file on APFS, so the
//  work lasts long enough to be met; every assertion that needs it in flight checks it still
//  runs afterwards and calls the race inconclusive otherwise (raise MACHMAN_TF_COPY_GIB).
//  The newer agent of R3W2-30 keeps its own library on APFS: an ad-hoc identity never
//  touches the volume. Second volumes are on by default (B-2); MACHMAN_LAB_VOLUMES=0 skips.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

@Suite(
	"Engine — long copies", .serialized,
	.enabled(if: Lab.runs(.l2) && TFGate.volumes, TFGate.volumesReason))
struct EngineLongWorkTests {
	static var gib: Int {
		Int(Lab.environment["MACHMAN_TF_COPY_GIB"] ?? "") ?? 3
	}

	/// An agent whose library is on a fresh HFS+ volume, for `body`.
	static func onHFS(
		_ name: String, answers: [String: Any] = [:],
		_ body: (LabAgent, String) async throws -> Void
	) async throws {
		try await TFVolume.with(.hfsPlus, gib: gib * 2 + 2, name: name) { volume in
			let data = volume.mountPoint + "/data"
			try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
			let options = LabAgent.Options(
				environment: ["MACHMAN_DATA_DIR": data], answers: answers)
			try await Lab.withAgent(options) { agent in try await body(agent, data) }
		}
	}

	/// The running operation on one of `vms` (a copy may name its source or its target),
	/// waited for.
	@discardableResult
	static func running(_ api: MachmanControlling, _ vms: String...) async throws
		-> OperationInfo {
		var found: OperationInfo?
		try await TFWait.until("a running operation on \(vms)", timeout: .seconds(60)) {
			found = try await api.operations().first {
				vms.contains($0.vm ?? "") && $0.state == OperationInfo.State.running
			}
			return found != nil
		}
		return found!
	}

	/// Throws inconclusive when `op` already finished: the refusals were met after the work.
	static func stillRunning(_ api: MachmanControlling, _ op: OperationInfo) async throws {
		let now = try await api.operations().first { $0.id == op.id }
		guard now?.state == OperationInfo.State.running else {
			throw TFError.inconclusive(
				"the \(op.kind) finished before the checks; raise MACHMAN_TF_COPY_GIB "
					+ "(now \(gib))")
		}
	}

	static func finished(_ api: MachmanControlling, _ op: OperationInfo) async throws {
		try await TFWait.until(
			"the \(op.kind) to finish", timeout: .seconds(600), every: .seconds(1)
		) {
			let now = try await api.operations().first { $0.id == op.id }
			return now == nil || now?.state == OperationInfo.State.succeeded
		}
	}

	/// A stopped VM "dev" with an owned storage disk of the copy size (the copy's bulk).
	static func devWithDisk(_ agent: LabAgent) async throws -> LabVM {
		let vm = try await LabVM.create(LabVMSpec(name: "dev", boot: .alpine()), on: agent)
		try await agent.api.addDisk(vm: "dev", .storage(name: "bulk", sizeBytes: UInt64(gib) << 30))
		let disk = TFVM.dir(dataDir: try await dataDir(agent), name: "dev")
		// HFS+ allocates the disk at once; fill it so the copy reads real blocks too.
		for entry in (try? FileManager.default.contentsOfDirectory(atPath: disk)) ?? []
		where entry.hasPrefix("bulk") {
			try await TFFiles.filled(disk + "/" + entry, bytes: gib << 30)
		}
		return vm
	}

	static func dataDir(_ agent: LabAgent) async throws -> String {
		agent.options.environment["MACHMAN_DATA_DIR"] ?? agent.scope.dataDir
	}

	@Test("R3W2-32: start, rename, delete and duplicate are refused while a disk imports")
	func refusedDuringImport() async throws {
		try await Self.onHFS("import-busy") { agent, _ in
			let api = agent.api
			_ = try await LabVM.create(LabVMSpec(name: "dev", boot: .alpine()), on: agent)
			let source = agent.scope.imagesDir + "/big.raw"
			try await TFFiles.filled(source, bytes: Self.gib << 30)
			let importing = Task { try await api.importDisk(vm: "dev", path: source) }
			let op = try await Self.running(api, "dev")
			let sentence = "dev is importing a disk — try again when it finishes"
			var refusals: [String] = []
			func refused(_ body: () async throws -> Void) async {
				do {
					try await body()
					refusals.append("(accepted)")
				} catch let error as MachmanError {
					refusals.append(error.message)
				} catch {
					refusals.append("\(error)")
				}
			}
			await refused {
				try await api.start(vm: "dev", options: StartOptions(openWindow: false))
			}
			await refused { try await api.renameVM(named: "dev", to: "dev2") }
			await refused { try await api.deleteVM(named: "dev") }
			await refused {
				_ = try await api.copyVM(
					vm: "dev", newName: "dev3", diskIDs: nil, mountIDs: nil, regenerateMAC: true)
			}
			try await Self.stillRunning(api, op)
			#expect(refusals == Array(repeating: sentence, count: 4))
			let info = try await importing.value
			#expect(info.disks.contains { $0.path?.hasSuffix("big.raw") == true })
			try await Self.finished(api, op)
		}
	}

	@Test(
		"""
		R3W2-29: an import into a running VM outlives the guest's shutdown, then the vmhost \
		exits
		""")
	func importOutlivesShutdown() async throws {
		try await Self.onHFS("import-outlives") { agent, _ in
			let api = agent.api
			let vm = try await LabVM.create(LabVMSpec(name: "dev", boot: .alpine()), on: agent)
			try await vm.start()
			let host = try await vm.hostPID()
			let console = try await vm.console(0)
			defer { console.close() }
			try await console.expect("LAB-READY", timeout: .seconds(60))
			let source = agent.scope.imagesDir + "/big.raw"
			try await TFFiles.filled(source, bytes: Self.gib << 30)
			let importing = Task { try await api.importDisk(vm: "dev", path: source) }
			let op = try await Self.running(api, "dev")
			try console.send("poweroff -f")
			try await vm.waitForState(.stopped, timeout: .seconds(30))
			#expect(LabProcesses.isAlive(host))
			try await Self.stillRunning(api, op)
			let info = try await importing.value
			#expect(info.disks.contains { $0.path?.hasSuffix("big.raw") == true })
			#expect(await LabProcesses.waitForExit(host, timeout: .seconds(30)))
			TFVM.forget(agent, "dev")
		}
	}

	/// "dev" running with an import into it, then its guest powered off: its vmhost
	/// finishes the import before it exits (E34). Returns the vmhost's pid, the operation and
	/// the import's call.
	static func drainingImport(_ agent: LabAgent) async throws
		-> (host: pid_t, op: OperationInfo, importing: Task<VMInfo, Error>) {
		let api = agent.api
		let vm = try await LabVM.create(LabVMSpec(name: "dev", boot: .alpine()), on: agent)
		try await vm.start()
		let host = try await vm.hostPID()
		let console = try await vm.console(0)
		defer { console.close() }
		try await console.expect("LAB-READY", timeout: .seconds(60))
		let source = agent.scope.imagesDir + "/big.raw"
		try await TFFiles.filled(source, bytes: Self.gib << 30)
		let importing = Task { try await api.importDisk(vm: "dev", path: source) }
		let op = try await Self.running(api, "dev")
		try console.send("poweroff -f")
		try await vm.waitForState(.stopped, timeout: .seconds(30))
		return (host, op, importing)
	}

	// E46: a vmhost finishing an import after its guest shut down (E34's drain) answered a
	// log out with terminateNow, and the import died with it.
	@Test(
		"""
		E46: a log out during a vmhost's import after its guest shut down is held by its own \
		alert
		""")
	func logOutDuringDrainHeld() async throws {
		try await Self.onHFS("import-logout") { agent, _ in
			let (host, op, importing) = try await Self.drainingImport(agent)
			let mark = LabLog.mark()
			#expect(try await !TFHosts.quit(
				agent, vm: "dev", host: host, reason: "logOut", timeout: .seconds(2)))
			_ = try await LabLog.waitFor(
				"logOut canceled: dev is importing a disk", after: mark, process: "MachmanVMHost")
			let held = try await LabLog.waitFor(
				SeamProbe.promptLine("vmhost.sessionEndDuringWork", "OK"), after: mark,
				process: "MachmanVMHost")
			#expect(held.eventMessage.contains("dev is importing a disk"))
			#expect(held.processID == Int(host))
			try await Self.stillRunning(agent.api, op)
			let info = try await importing.value
			#expect(info.disks.contains { $0.path?.hasSuffix("big.raw") == true })
			#expect(await LabProcesses.waitForExit(host, timeout: .seconds(30)))
			TFVM.forget(agent, "dev")
		}
	}

	// C24: the user's own quit in that drain asks first; Cancel keeps the import.
	@Test("E46: quitting a vmhost during its import after the guest shut down asks first")
	func quitDuringDrainAsks() async throws {
		try await Self.onHFS("import-quit") { agent, _ in
			let (host, op, importing) = try await Self.drainingImport(agent)
			let mark = LabLog.mark()
			#expect(try await !TFHosts.quit(
				agent, vm: "dev", host: host, reason: "userQuit", timeout: .seconds(2)))
			let asked = try await LabLog.waitFor(
				SeamProbe.promptLine("vmhost.quitDuringWork", "Cancel"), after: mark,
				process: "MachmanVMHost")
			#expect(asked.eventMessage.contains("dev is importing a disk — quit anyway?"))
			try await Self.stillRunning(agent.api, op)
			let info = try await importing.value
			#expect(info.disks.contains { $0.path?.hasSuffix("big.raw") == true })
			#expect(await LabProcesses.waitForExit(host, timeout: .seconds(30)))
			TFVM.forget(agent, "dev")
		}
	}

	@Test("R3W2-31: quitting the agent during a copy asks, and Cancel keeps both VMs")
	func quitDuringCopyAsks() async throws {
		try await Self.onHFS("copy-quit", answers: ["agent.quitDuringWork": "Cancel"]) { agent, _ in
			let api = agent.api
			_ = try await Self.devWithDisk(agent)
			let copying = Task {
				try await api.copyVM(
					vm: "dev", newName: "dev copy", diskIDs: nil, mountIDs: nil,
					regenerateMAC: true)
			}
			let op = try await Self.running(api, "dev copy", "dev")
			let mark = LabLog.mark()
			#expect(try await agent.control("quit userQuit") == "ok")
			let prompt = try await LabLog.waitFor(
				SeamProbe.promptLine("agent.quitDuringWork", "Cancel"), after: mark,
				process: "MachmanAgent")
			try await Self.stillRunning(api, op)
			#expect(prompt.eventMessage.contains("dev is being copied — quit anyway?"))
			try await Task.sleep(for: .seconds(1))
			#expect(LabProcesses.isAlive(agent.pid))
			_ = try await copying.value
			let names = Set(try await api.listVMs().map(\.name))
			#expect(names.isSuperset(of: ["dev", "dev copy"]))
		}
	}

	@Test("R3W2-31: a log out during a copy is canceled with the agent's own alert")
	func logOutDuringCopyHeld() async throws {
		try await Self.onHFS("copy-logout") { agent, _ in
			let api = agent.api
			_ = try await Self.devWithDisk(agent)
			let copying = Task {
				try await api.copyVM(
					vm: "dev", newName: "dev copy", diskIDs: nil, mountIDs: nil,
					regenerateMAC: true)
			}
			let op = try await Self.running(api, "dev copy", "dev")
			let mark = LabLog.mark()
			#expect(try await agent.control("quit logOut") == "ok")
			_ = try await LabLog.waitFor(
				"logOut canceled: dev is being copied", after: mark, process: "MachmanAgent")
			try await Self.stillRunning(api, op)
			let held = try await LabLog.waitFor(
				SeamProbe.promptLine("agent.sessionEndHeld", "OK"), after: mark,
				process: "MachmanAgent")
			#expect(held.eventMessage.contains("dev is being copied"))
			try await Task.sleep(for: .seconds(1))
			#expect(LabProcesses.isAlive(agent.pid))
			_ = try await copying.value
		}
	}

	@Test("R3W2-30: a newer agent's Replace is refused while the serving agent copies a VM")
	func newerReplaceRefused() async throws {
		let answers: [String: Any] = [
			"agent.replaceOlder": "Replace", "agent.replaceRefused": "OK",
		]
		try await Self.onHFS("copy-agent-replace", answers: answers) { agent, _ in
			let api = agent.api
			_ = try await Self.devWithDisk(agent)
			let copying = Task {
				try await api.copyVM(
					vm: "dev", newName: "dev copy", diskIDs: nil, mountIDs: nil,
					regenerateMAC: true)
			}
			let op = try await Self.running(api, "dev copy", "dev")
			let newer = TFBuilds.newerVersion(than: TFBuilds.current)
			let ownData = agent.scope.dir + "/newer-data"
			try FileManager.default.createDirectory(
				atPath: ownData, withIntermediateDirectories: true)
			let mark = LabLog.mark()
			let pid = try await TFAgents.launchSecond(
				scope: agent.scope,
				options: LabAgent.Options(
					environment: ["MACHMAN_DATA_DIR": ownData],
					appURL: try await TFBuilds.agentApp(newer)))
			defer { Task { await TFAgents.stopSecond(pid: pid, api: nil, scope: agent.scope) } }
			#expect(await LabProcesses.waitForExit(pid, timeout: .seconds(30)))
			let lines = TFAgents.logLines(after: mark, pid: pid, matching: "test prompt|retire")
			let asked = lines.firstIndex { $0.contains("test prompt agent.replaceOlder") }
			let refused = lines.firstIndex { $0.contains("test prompt agent.replaceRefused") }
			#expect(asked != nil && refused != nil && asked! < refused!)
			#expect(lines.contains {
				$0.contains("can't retire yet (dev is being copied — try again when it finishes)")
			})
			#expect(LabProcesses.isAlive(agent.pid))
			let check = try await agent.connect(clientName: "machman-lab-tf")
			#expect(check.hello.daemonVersion == TFBuilds.current)
			await check.disconnect()
			try await Self.stillRunning(api, op)
			_ = try await copying.value
			let names = Set(try await api.listVMs().map(\.name))
			#expect(names.isSuperset(of: ["dev", "dev copy"]))
		}
		await TFBuilds.unregisterAll()
	}

	@Test("R3W2-30: a desktop Replace during a copy is refused with the copy as the reason")
	func desktopReplaceRefused() async throws {
		try await Self.onHFS("copy-desk-replace") { agent, _ in
			let api = agent.api
			_ = try await Self.devWithDisk(agent)
			let copying = Task {
				try await api.copyVM(
					vm: "dev", newName: "dev copy", diskIDs: nil, mountIDs: nil,
					regenerateMAC: true)
			}
			let op = try await Self.running(api, "dev copy", "dev")
			let desktop = try await agent.connect(clientName: "MachmanDesktop-lab")
			var refusal: MachmanError?
			do {
				try await desktop.retire()
			} catch let error as MachmanError {
				refusal = error
			}
			await desktop.disconnect()
			let error = try #require(refusal)
			#expect(error.code == .invalidState)
			#expect(error.message == "dev is being copied — try again when it finishes")
			let prompt = DaemonVersionPrompt.replaceRefused(reason: error.message)
			#expect(prompt.title == "Machman Agent can’t be replaced yet")
			#expect(prompt.message == error.message + ".")
			try await Self.stillRunning(api, op)
			#expect(try await agent.control("ping") == "ok")
			_ = try await copying.value
		}
	}
}
