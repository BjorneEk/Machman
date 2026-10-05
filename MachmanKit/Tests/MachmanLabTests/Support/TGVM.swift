//
//  TGVM.swift
//  MachmanLabTests
//
//  A VM of an r3-tg test, by name, over the scope's agent (whichever instance serves it now:
//  the safe-mode rows relaunch the agent mid-test). LabVM builds the Alpine VM; this adds
//  what LabVM's start can't say — safe and forced starts, storage disks, external images,
//  mounts and their safe/enabled flags, a start policy — and handles the VMs the product
//  makes (a run saved as a new VM, a duplicate). A vmhost's pid file follows the VM that
//  owns the run, so the guest cap and the agent's teardown keep seeing it after a save.
//

import Foundation
import MachmanAPI
import MachmanClient
import MachmanUI

struct TGDisk: Sendable {
	var name: String
	var mib: Int
	var safe = true
	var enabled = true

	var sizeBytes: UInt64 { UInt64(mib) << 20 }
	var sectors: Int { mib * 2048 }
}

struct TGExternal: Sendable {
	var path: String
	var safe = true
}

struct TGMount: Sendable {
	var path: String
	var tag: String
	var safe = true
}

final class TGVM: @unchecked Sendable {
	let agent: LabAgent
	let name: String

	init(_ name: String, on agent: LabAgent) {
		self.agent = agent
		self.name = name
	}

	var api: RemoteMachman { agent.api }
	var scope: LabScope { agent.scope }
	var pidName: String { "\(scope.id)-\(name)" }
	var socketPath: String { MachmanPaths.vmSocketPath(vm: name) }
	var dir: String { TG.vmDir(scope, name) }

	/// An Alpine VM (LabVM's), then its disks in order (storage first, then images), mounts,
	/// the flags that differ from the defaults, and the start policy.
	static func alpine(
		_ name: String, disks: [TGDisk] = [], externals: [TGExternal] = [],
		mounts: [TGMount] = [], policy: StartPolicy = StartPolicy(windowed: false),
		on agent: LabAgent
	) async throws -> TGVM {
		_ = try await LabVM.create(LabVMSpec(name: name, boot: .alpine()), on: agent)
		let vm = TGVM(name, on: agent)
		try await vm.configure(disks: disks, externals: externals, mounts: mounts, policy: policy)
		return vm
	}

	/// A VM that never boots (the disk-ownership rows): the .blank template, renamed.
	static func blank(_ name: String, on agent: LabAgent) async throws -> TGVM {
		let info = try await agent.api.createVM(template: .blank)
		try await agent.api.renameVM(named: info.name, to: name)
		return TGVM(name, on: agent)
	}

	func configure(
		disks: [TGDisk], externals: [TGExternal], mounts: [TGMount], policy: StartPolicy?
	) async throws {
		for disk in disks {
			try await api.addDisk(vm: name, .storage(name: disk.name, sizeBytes: disk.sizeBytes))
		}
		for external in externals { try await api.addDisk(vm: name, .image(path: external.path)) }
		for mount in mounts {
			try await api.addMount(vm: name, path: mount.path, tag: mount.tag, kind: nil)
		}
		let info = try await info()
		var diskSafety: [String: Bool] = [:]
		var diskEnabled: [String: Bool] = [:]
		for disk in disks {
			let id = try Self.diskID(in: info, named: disk.name)
			if !disk.safe { diskSafety[id] = false }
			if !disk.enabled { diskEnabled[id] = false }
		}
		for external in externals where !external.safe {
			diskSafety[try Self.diskID(in: info, path: external.path)] = false
		}
		var mountSafety: [String: Bool] = [:]
		for mount in mounts where !mount.safe {
			guard let id = info.mounts.first(where: { $0.tag == mount.tag })?.id else {
				throw LabError.specInvalid("\(name) has no mount tagged \(mount.tag)")
			}
			mountSafety[id] = false
		}
		if !diskSafety.isEmpty || !mountSafety.isEmpty {
			try await api.setSafety(
				vm: name, disks: diskSafety.isEmpty ? nil : diskSafety,
				mounts: mountSafety.isEmpty ? nil : mountSafety)
		}
		if !diskEnabled.isEmpty {
			try await api.setEnabled(
				vm: name, disks: diskEnabled, mounts: nil, console: nil, uart: nil)
		}
		if let policy { try await api.setStartPolicy(vm: name, policy: policy) }
	}

	static func diskID(in info: VMInfo, named disk: String) throws -> String {
		guard let id = info.disks.first(where: { $0.type == .storage && $0.name == disk })?.id
		else { throw LabError.specInvalid("\(info.name) has no storage disk \(disk)") }
		return id
	}

	static func diskID(in info: VMInfo, path: String) throws -> String {
		guard let id = info.disks.first(where: { $0.path == path })?.id else {
			throw LabError.specInvalid("\(info.name) has no disk at \(path)")
		}
		return id
	}

	// MARK: State

	func info() async throws -> VMInfo { try await api.vm(named: name) }

	func disk(named disk: String) async throws -> DiskInfo {
		let info = try await info()
		let id = try Self.diskID(in: info, named: disk)
		return info.disks.first { $0.id == id }!
	}

	func disk(path: String) async throws -> DiskInfo {
		let info = try await info()
		let id = try Self.diskID(in: info, path: path)
		return info.disks.first { $0.id == id }!
	}

	func waitForState(_ wanted: VMState, timeout: Duration = .seconds(60)) async throws {
		let deadline = ContinuousClock.now + timeout
		var last = "unknown"
		while true {
			let state = try await info().state
			last = state.rawValue
			if state == wanted { return }
			if ContinuousClock.now >= deadline {
				throw LabError.stateTimeout(vm: name, wanted: wanted.rawValue, last: last)
			}
			try await Task.sleep(for: .milliseconds(250))
		}
	}

	// MARK: Runs

	/// A start with exact options; returns once the VM runs and its vmhost's pid is filed.
	func start(_ options: StartOptions, timeout: Duration = .seconds(90)) async throws {
		let running = LabProcesses.liveGuestCount()
		if running >= 2 { throw LabError.guestCap(running: running) }
		try await api.start(vm: name, options: options)
		try await waitForState(.running, timeout: timeout)
		try fileHostPid(try await hostPID())
	}

	/// The start's refusal, or nil when it started (the run is then stopped again).
	func startError(_ options: StartOptions) async throws -> MachmanError? {
		do {
			try await start(options)
		} catch let error as MachmanError {
			return error
		}
		try await forceStop()
		return nil
	}

	/// Force Stop, then the vmhost's exit (until then the agent counts the VM as hosted).
	func forceStop(timeout: Duration = .seconds(60)) async throws {
		let host = try? await hostPID()
		try await api.stop(vm: name, mode: .force)
		try await stopped(host: host, timeout: timeout)
	}

	/// Waits for a run that ends by itself (a guest power-off, a killed vmhost).
	func stopped(host: pid_t? = nil, timeout: Duration = .seconds(60)) async throws {
		try await waitForState(.stopped, timeout: timeout)
		let pid = host ?? filedHostPid()
		if let pid { _ = await LabProcesses.waitForExit(pid, timeout: .seconds(30)) }
		LabProcesses.removePid(kind: "vmhost", name: pidName)
	}

	func hostPID() async throws -> pid_t {
		guard let pid = await TG.socketPeer(socketPath) else {
			throw LabError.agentDidNotStart("nothing serves \(name)'s vmhost socket")
		}
		return pid
	}

	func fileHostPid(_ pid: pid_t) throws {
		try LabProcesses.writePid(pid, kind: "vmhost", name: pidName)
	}

	func filedHostPid() -> pid_t? {
		LabProcesses.pids(kind: "vmhost", namePrefix: pidName).first
	}

	/// After a save, the run's vmhost is `saved`'s: its pid file moves with it.
	func handOverPid(to saved: TGVM) throws {
		if let pid = filedHostPid() { try saved.fileHostPid(pid) }
		LabProcesses.removePid(kind: "vmhost", name: pidName)
	}

	// MARK: Consoles

	func consoleSocketPath(_ index: Int = 0) async throws -> String {
		let deadline = ContinuousClock.now + .seconds(10)
		while true {
			let ports = try await info().consolePorts ?? []
			if let path = ports.first(where: { $0.index == index })?.socketPath { return path }
			if ContinuousClock.now >= deadline {
				throw LabError.consoleUnavailable("\(name) has no console \(index) socket")
			}
			try await Task.sleep(for: .milliseconds(250))
		}
	}

	/// A new console client on port `index` (each with its own transcript).
	func console(_ index: Int = 0) async throws -> LabConsole {
		try await LabConsole.connect(
			try await consoleSocketPath(index),
			transcript: "\(pidName)-hvc\(index)-\(TG.nonce())")
	}

	/// The booted guest's shell on hvc0.
	func guest() async throws -> TGGuest { try await TGGuest.ready(try await console(0)) }
}
