//
//  TFVMs.swift
//  MachmanLabTests
//
//  A lab VM's files and starts as the engine rows need them: its folder and config in the
//  scope's library, a start with options LabVM.start doesn't take, the vmhost's pid file (the
//  sweeps and the guest cap read it), and hand edits of a STOPPED VM's config (the agent is
//  never running while one is written: TFAgents.restartForEdit). TFGuest drives the Alpine
//  fixture's shell on hvc0.
//

import Foundation
import MachmanAPI
import MachmanClient

enum TFVM {
	static func dir(dataDir: String, name: String) -> String {
		MachmanPaths.vmsDir(dataDir: dataDir) + "/" + name
	}

	static func config(dir: String) -> String { dir + "/config" }

	static func dir(_ agent: LabAgent, _ name: String) -> String {
		dir(dataDir: agent.scope.dataDir, name: name)
	}

	static func pidName(scope: LabScope, vm: String) -> String { "\(scope.id)-\(vm)" }

	/// LabVM.start's shape with any options: the guest cap, the start, running, the pid file.
	static func start(
		_ agent: LabAgent, _ name: String,
		options: StartOptions = StartOptions(openWindow: false), timeout: Duration = .seconds(90)
	) async throws {
		let running = LabProcesses.liveGuestCount()
		if running >= 2 { throw LabError.guestCap(running: running) }
		try await agent.api.start(vm: name, options: options)
		try await TFWait.state(agent.api, name, .running, timeout: timeout)
		_ = try await recordHost(agent, name)
	}

	/// The pid serving `name`'s vmhost socket (its peer), not recorded.
	static func peer(_ name: String) async throws -> pid_t {
		let host = try await RemoteMachman(
			socketPath: MachmanPaths.vmSocketPath(vm: name), clientName: "machman-lab-pid")
		let pid = host.peerPID
		await host.disconnect()
		guard let pid else { throw TFError.precondition("no peer pid for \(name)'s vmhost") }
		return pid
	}

	/// The vmhost serving `name`, written to the run's pid files.
	@discardableResult
	static func recordHost(_ agent: LabAgent, _ name: String) async throws -> pid_t {
		let pid = try await peer(name)
		try LabProcesses.writePid(pid, kind: "vmhost", name: pidName(scope: agent.scope, vm: name))
		return pid
	}

	static func forget(_ agent: LabAgent, _ name: String) {
		LabProcesses.removePid(kind: "vmhost", name: pidName(scope: agent.scope, vm: name))
	}

	/// Force-stops `name` if it runs, waits for its vmhost to go, and forgets its pid file.
	static func forceStop(_ agent: LabAgent, _ name: String) async {
		let file = LabProcesses.pidFile(kind: "vmhost", name: pidName(scope: agent.scope, vm: name))
		let host = (try? String(contentsOfFile: file, encoding: .utf8))
			.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
		if let state = try? await agent.api.vm(named: name).state, state.isRunning {
			try? await agent.api.stop(vm: name, mode: .force)
			_ = try? await TFWait.state(agent.api, name, .stopped, timeout: .seconds(60))
		}
		if let host { _ = await LabProcesses.waitForExit(host, timeout: .seconds(30)) }
		forget(agent, name)
	}

	/// `body`, retried for a few seconds while the agent settles a stop: a call that races a
	/// vmhost's exit meets its closing connection, or a VM the agent still counts as hosted.
	@discardableResult
	static func settled<T>(_ body: () async throws -> T) async throws -> T {
		try await LabRetry.settled("a call", retry: { _ in true }, body)
	}

	/// Rewrites a stopped VM's config through a JSON round trip: unknown keys stay, the file
	/// is replaced atomically.
	static func editConfig(dir: String, _ body: (inout [String: Any]) throws -> Void) throws {
		let url = URL(fileURLWithPath: config(dir: dir))
		let data = try Data(contentsOf: url)
		guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw TFError.precondition("\(url.path) is not a JSON object")
		}
		try body(&object)
		let out = try JSONSerialization.data(
			withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
		try out.write(to: url, options: .atomic)
	}

	/// The config as a JSON object (read only).
	static func readConfig(dir: String) throws -> [String: Any] {
		let data = try Data(contentsOf: URL(fileURLWithPath: config(dir: dir)))
		guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw TFError.precondition("\(dir)/config is not a JSON object")
		}
		return object
	}

	/// `value` as sorted-key JSON, for byte-for-byte comparisons of a config fragment.
	static func canonicalJSON(_ value: Any) throws -> Data {
		try JSONSerialization.data(
			withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
	}
}

/// The Alpine fixture's shell on hvc0, once LAB-READY: network, the virtiofs share, a report.
enum TFGuest {
	/// DHCP on eth0 (the VZ NAT network); the lease is what the agent's discovery reads.
	static func dhcp(_ console: LabConsole) async throws {
		let result = try await console.run(
			"modprobe -q virtio_net 2>/dev/null; ip link set eth0 up && "
				+ "udhcpc -i eth0 -n -q -t 5 -T 2 >/dev/null 2>&1", timeout: .seconds(60))
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "udhcpc", status: result.status, output: result.output)
		}
	}

	/// Mounts the VM's one virtiofs share (tag host-share) at /mnt/s; returns the path.
	@discardableResult
	static func mountShare(_ console: LabConsole) async throws -> String {
		let result = try await console.run(
			"modprobe -q virtiofs 2>/dev/null; mkdir -p /mnt/s && "
				+ "(mountpoint -q /mnt/s || mount -t virtiofs host-share /mnt/s)")
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "mount host-share", status: result.status, output: result.output)
		}
		return "/mnt/s"
	}

	/// Writes `text` as the share's GuestReport/report.env (the vmhost polls it).
	static func writeReport(_ console: LabConsole, _ text: String) async throws {
		let quoted = ShellQuote.single(text)
		let result = try await console.run(
			"mkdir -p /mnt/s/GuestReport && printf '%s\\n' \(quoted) > /mnt/s/GuestReport/.r "
				+ "&& mv /mnt/s/GuestReport/.r /mnt/s/GuestReport/report.env && sync")
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "write report.env", status: result.status, output: result.output)
		}
	}

	/// A port-22 listener that accepts and closes, forever (stands in for sshd).
	static func listen22(_ console: LabConsole) async throws {
		_ = try await console.run("(while :; do nc -l -p 22 </dev/null; done) >/dev/null 2>&1 &")
	}

	/// The guest's own IPv4 address on the VM network, once DHCP gave it one (iproute2's ip,
	/// as on the Debian image; up to a minute).
	static func address(_ console: LabConsole) async throws -> String {
		let show = "ip -4 -o addr show scope global"
		let result = try await console.run(
			"for i in $(seq 60); do \(show) | grep -q inet && break; sleep 1; done; \(show)",
			timeout: .seconds(90))
		guard let found = result.output.range(of: #"inet [0-9.]+/"#, options: .regularExpression)
		else {
			throw LabError.commandFailed(
				command: show, status: result.status, output: result.output)
		}
		return String(result.output[found].dropFirst("inet ".count).dropLast())
	}
}
