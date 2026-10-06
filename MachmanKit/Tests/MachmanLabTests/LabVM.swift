//
//  LabVM.swift
//  MachmanLabTests
//
//  A lab VM, built over the wire from the .blank template: no graphics, audio, HID or
//  clipboard unless the spec asks for it (never audio), headless, one or two vCPUs and at
//  most 2 GiB. Fixtures are cloned into the scope's images dir, never booted in place.
//

import Foundation
import MachmanAPI
import MachmanClient

struct LabVMSpec: Sendable {
	enum Boot: Sendable, Equatable {
		case alpine(cmdline: String = LabVMSpec.alpineCommandLine)
		case efiImage(fixture: String)
		case efiImagePath(String)
	}

	struct Mount: Sendable, Equatable {
		var path: String
		var tag: String
	}

	static let alpineCommandLine = "console=hvc0 rdinit=/lab-init loglevel=3"

	var name: String
	var boot: Boot
	var cpus = 1
	var memoryGiB = 1
	var consolePorts = 2
	var network = false
	var devices: [DeviceKind] = []
	var mounts: [Mount] = []
	/// Raw images attached after the boot disk (each as a clone), in order.
	var extraDisks: [String] = []

	init(
		name: String, boot: Boot, cpus: Int = 1, memoryGiB: Int = 1, consolePorts: Int = 2,
		network: Bool = false, devices: [DeviceKind] = [], mounts: [Mount] = [],
		extraDisks: [String] = []
	) {
		self.name = name
		self.boot = boot
		self.cpus = cpus
		self.memoryGiB = memoryGiB
		self.consolePorts = consolePorts
		self.network = network
		self.devices = devices
		self.mounts = mounts
		self.extraDisks = extraDisks
	}

	func validate() throws {
		if name.isEmpty || name.contains("/") || name.hasPrefix(".") {
			throw LabError.specInvalid(
				"a lab VM name can't be empty, contain '/' or start with '.'")
		}
		guard (1...2).contains(cpus) else {
			throw LabError.specInvalid("a lab VM gets 1 or 2 vCPUs, not \(cpus)")
		}
		guard (1...2).contains(memoryGiB) else {
			throw LabError.specInvalid("a lab VM gets 1 or 2 GiB, not \(memoryGiB)")
		}
		guard (1...4).contains(consolePorts) else {
			throw LabError.specInvalid("a lab VM gets 1 to 4 consoles, not \(consolePorts)")
		}
		if devices.contains(.audioInput) || devices.contains(.audioOutput) {
			throw LabError.specInvalid("a lab VM never gets audio devices (permission prompts)")
		}
	}
}

final class LabVM: @unchecked Sendable {
	let agent: LabAgent
	let name: String

	private init(agent: LabAgent, name: String) {
		self.agent = agent
		self.name = name
	}

	private var api: RemoteMachman { agent.api }

	static func create(_ spec: LabVMSpec, on agent: LabAgent) async throws -> LabVM {
		try spec.validate()
		let api = agent.api
		let info = try await api.createVM(template: .blank)
		try await api.renameVM(named: info.name, to: spec.name)
		let vm = LabVM(agent: agent, name: spec.name)
		try await api.setHardware(
			vm: spec.name, cpuCount: spec.cpus, memoryBytes: UInt64(spec.memoryGiB) << 30,
			nestedVirtualization: nil)
		for _ in 0..<spec.consolePorts { try await api.addConsolePort(vm: spec.name) }
		if spec.network { _ = try await api.addDevice(vm: spec.name, kind: .network) }
		for kind in spec.devices { _ = try await api.addDevice(vm: spec.name, kind: kind) }
		let images = agent.scope.imagesDir
		switch spec.boot {
		case .alpine(let cmdline):
			let alpine = try await LabFixtures.alpine()
			let kernel = try await LabFixtures.clone(
				alpine.kernel, as: "\(spec.name)-Image", into: images)
			let initrd = try await LabFixtures.clone(
				alpine.initramfs, as: "\(spec.name)-initramfs", into: images)
			try await api.setKernelBoot(vm: spec.name, enabled: true)
			try await api.updateKernelSettings(
				vm: spec.name,
				KernelSettings(kernelPath: kernel, initrdPath: initrd, commandLine: cmdline))
		case .efiImage(let fixture):
			let image = try await LabFixtures.clone(
				try LabFixtures.path(fixture), as: "\(spec.name)-\(fixture)", into: images)
			try await api.addDisk(vm: spec.name, .image(path: image))
		case .efiImagePath(let path):
			let image = try await LabFixtures.clone(
				path, as: "\(spec.name)-\((path as NSString).lastPathComponent)", into: images)
			try await api.addDisk(vm: spec.name, .image(path: image))
		}
		try await vm.attachClones(of: spec.extraDisks)
		for mount in spec.mounts {
			try await api.addMount(vm: spec.name, path: mount.path, tag: mount.tag, kind: nil)
		}
		return vm
	}

	private var pidName: String { "\(agent.scope.id)-\(name)" }

	func start(timeout: Duration = .seconds(90)) async throws {
		let running = LabProcesses.liveGuestCount()
		if running >= 2 { throw LabError.guestCap(running: running) }
		try await api.start(vm: name, options: StartOptions(openWindow: false))
		try await waitForState(.running, timeout: timeout)
		try LabProcesses.writePid(try await hostPID(), kind: "vmhost", name: pidName)
	}

	func stop(_ mode: StopMode = .force, timeout: Duration = .seconds(60)) async throws {
		try await api.stop(vm: name, mode: mode)
		try await waitForState(.stopped, timeout: timeout)
		LabProcesses.removePid(kind: "vmhost", name: pidName)
	}

	func info() async throws -> VMInfo {
		guard let found = try await api.listVMs().first(where: { $0.name == name }) else {
			throw LabError.specInvalid("\(name) isn't in the lab library any more")
		}
		return found
	}

	func waitForState(_ wanted: VMState, timeout: Duration) async throws {
		try await LabStep.run(
			"\(name): waiting ≤\(LabStep.format(timeout)) for \(wanted.rawValue)"
		) {
			let deadline = ContinuousClock.now + timeout
			var last = "unknown"
			while true {
				let state = try await info().state
				last = state.rawValue
				if state == wanted { return }
				if state == .error {
					throw LabError.stateTimeout(vm: name, wanted: wanted.rawValue, last: "error")
				}
				if ContinuousClock.now >= deadline {
					throw LabError.stateTimeout(vm: name, wanted: wanted.rawValue, last: last)
				}
				try await Task.sleep(for: .milliseconds(250))
			}
		}
	}

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

	func console(_ index: Int = 0) async throws -> LabConsole {
		try await LabConsole.connect(
			try await consoleSocketPath(index), transcript: "\(pidName)-hvc\(index)",
			title: "\(name) hvc\(index)")
	}

	/// A console on port `index` with `user` logged in. A login that stalls (the typed name
	/// is never echoed) is retried on a fresh connection, `tries` in all, each logged.
	func loggedInConsole(
		_ index: Int, user: String = "root", label: String, timeout: Duration = .seconds(300),
		tries: Int = 3
	) async throws -> LabConsole {
		var attempt = 1
		while true {
			let suffix = attempt == 1 ? "" : "-try\(attempt)"
			let console = try await LabConsole.connect(
				try await consoleSocketPath(index), transcript: "\(pidName)-\(label)\(suffix)",
				title: "\(name) \(label)")
			do {
				try await console.login(user: user, timeout: attempt == 1 ? timeout : .seconds(60))
				return console
			} catch let error as LabError where attempt < tries {
				MachmanLogger.log(
					.passiveWarning,
					"lab: \(name) console \(index): login try \(attempt) failed, reconnecting: "
						+ "\(error)")
				console.close()
				attempt += 1
				try await Task.sleep(for: .seconds(1))
			}
		}
	}

	/// Starts the VM unless it runs and logs `user` in on console `index`. A boot whose
	/// console takes no input (seen on Debian 13 under VZ, about one boot in ten: the getty's
	/// prompt arrives, typed text never reaches it, on any connection) is force-stopped and
	/// booted again, `boots` boots in all, each logged.
	func bootLoggedIn(
		_ index: Int, user: String = "root", label: String, boots: Int = 3
	) async throws -> LabConsole {
		var boot = 1
		while true {
			if try await info().state != .running { try await start(timeout: .seconds(120)) }
			do {
				return try await loggedInConsole(
					index, user: user, label: boot == 1 ? label : "\(label)-boot\(boot)",
					tries: 1)
			} catch let error as LabError where boot < boots {
				MachmanLogger.log(
					.passiveWarning,
					"lab: \(name) console \(index): no login on boot \(boot) of \(boots), booting"
						+ " again: \(error)")
				try await api.stop(vm: name, mode: .force)
				try await waitForState(.stopped, timeout: .seconds(60))
				await awaitHostExit()
				boot += 1
			}
		}
	}

	/// The vmhost's pid, through its socket's peer.
	func hostPID(socketPath: String? = nil) async throws -> pid_t {
		let host = try await RemoteMachman(
			socketPath: socketPath ?? MachmanPaths.vmSocketPath(vm: name),
			clientName: "machman-lab-pid")
		let pid = host.peerPID
		await host.disconnect()
		guard let pid else { throw LabError.agentDidNotStart("no peer pid for \(name)'s vmhost") }
		return pid
	}

	func delete() async throws { try await api.deleteVM(named: name) }

	/// Waits for a VM whose guest powered itself off (VZ has no reset: a guest reboot stops
	/// the VM too) and for its vmhost to exit — until then the agent still counts the VM as
	/// hosted and refuses config changes — then drops the vmhost's pid file.
	func guestStopped(timeout: Duration = .seconds(180)) async throws {
		try await waitForState(.stopped, timeout: timeout)
		await awaitHostExit()
	}

	// The vmhost named by the pid file exits a moment after its VM reads stopped; until then
	// the agent counts the VM as hosted. Then the pid file goes.
	private func awaitHostExit() async {
		let file = LabProcesses.pidFile(kind: "vmhost", name: pidName)
		if let text = try? String(contentsOfFile: file, encoding: .utf8),
			let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
			_ = await LabProcesses.waitForExit(pid, timeout: .seconds(30))
		}
		LabProcesses.removePid(kind: "vmhost", name: pidName)
	}

	/// A stopped VM's disks replaced by fresh clones of `boot` and `extra` (the old clones
	/// deleted): the next start sees pristine images under the same VM (and MAC).
	func replaceDisks(boot: String, extra: [String] = []) async throws {
		for disk in try await info().disks {
			try await settled { try await api.removeDisk(vm: name, diskID: disk.id) }
			if let path = disk.path, path.hasPrefix(agent.scope.imagesDir + "/") {
				try? FileManager.default.removeItem(atPath: path)
			}
		}
		try await attachClones(of: [boot] + extra)
	}

	// `body`, retried for a few seconds while the agent still settles a stop (invalidState).
	private func settled<T>(_ body: () async throws -> T) async throws -> T {
		let deadline = ContinuousClock.now + .seconds(30)
		while true {
			do {
				return try await body()
			} catch let error as MachmanError
				where error.code == .invalidState && ContinuousClock.now < deadline {
				try await Task.sleep(for: .milliseconds(250))
			}
		}
	}

	fileprivate func attachClones(of paths: [String]) async throws {
		for path in paths {
			let image = try await LabFixtures.clone(
				path, as: "\(name)-\((path as NSString).lastPathComponent)",
				into: agent.scope.imagesDir)
			try await api.addDisk(vm: name, .image(path: image))
		}
	}
}

extension LabAgent {
	/// A VM for `body`; stopped and deleted on every path.
	func withVM<T>(
		_ spec: LabVMSpec, start: Bool = true, _ body: (LabVM) async throws -> T
	) async throws -> T {
		let vm = try await LabVM.create(spec, on: self)
		do {
			if start { try await vm.start() }
			let result = try await body(vm)
			await vm.cleanup()
			return result
		} catch {
			await vm.cleanup()
			throw error
		}
	}
}

extension LabVM {
	fileprivate func cleanup() async {
		if let state = try? await info().state, state.isRunning { try? await stop(.force) }
		try? await delete()
		LabProcesses.removePid(kind: "vmhost", name: "\(agent.scope.id)-\(name)")
	}
}
