//
//  TGLab.swift
//  MachmanLabTests
//
//  r3-tg's lab helpers: where a scope keeps its library and safe runs, the files a test
//  reads (hashes, byte ranges, run-root markers), hand edits of a VM's config the way a
//  person's text editor would make them, and the agent moves the safe-mode rows need (a
//  quit that leaves VMs running, a SIGKILL of a pid the harness knows). Reads only, except
//  the files a test writes into its own scope.
//

import CryptoKit
import Foundation
import MachmanAPI
import MachmanClient
import MachmanTestSupport

enum TG {
	// MARK: Scope paths

	static func vmsDir(_ scope: LabScope) -> String { MachmanPaths.vmsDir(dataDir: scope.dataDir) }

	static func vmDir(_ scope: LabScope, _ vm: String) -> String { vmsDir(scope) + "/" + vm }

	static func safeDir(_ scope: LabScope) -> String {
		MachmanPaths.safeRunsDir(dataDir: scope.dataDir)
	}

	/// The run roots (`run-*`) in `dir`, sorted, as full paths.
	static func runRoots(in dir: String) -> [String] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
		return names.filter { $0.hasPrefix("run-") }.sorted().map { dir + "/" + $0 }
	}

	static func runRoots(_ scope: LabScope) -> [String] { runRoots(in: safeDir(scope)) }

	/// Polls until the scope has no run root, `timeout` at most; returns what is left.
	static func waitForNoRunRoots(_ scope: LabScope, timeout: Duration = .seconds(15)) async
		-> [String] {
		let deadline = ContinuousClock.now + timeout
		while true {
			let left = runRoots(scope)
			if left.isEmpty || ContinuousClock.now >= deadline { return left }
			try? await Task.sleep(for: .milliseconds(200))
		}
	}

	struct Marker: Equatable {
		var vm: String
		var pid: Int32?
	}

	/// A run root's machman-shadow.json, read as plain JSON (its type is internal to Core).
	static func marker(_ runRoot: String) -> Marker? {
		guard let data = FileManager.default.contents(atPath: runRoot + "/machman-shadow.json"),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let vm = object["vm"] as? String else { return nil }
		return Marker(vm: vm, pid: (object["pid"] as? NSNumber)?.int32Value)
	}

	// MARK: Files

	/// The file's sha256 as hex, read in 1 MiB slices on a thread of its own.
	static func sha256(_ path: String) async throws -> String {
		let result: Result<String, Error> = await offPool {
			do {
				let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
				defer { try? handle.close() }
				var hasher = SHA256()
				while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
					hasher.update(data: chunk)
				}
				return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
			} catch {
				return .failure(error)
			}
		}
		return try result.get()
	}

	/// `count` bytes at `offset` (fewer at the end of the file).
	static func bytes(_ path: String, offset: UInt64, count: Int) throws -> Data {
		let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
		defer { try? handle.close() }
		try handle.seek(toOffset: offset)
		return try handle.read(upToCount: count) ?? Data()
	}

	/// Polls the host file until `text` sits at `offset`, `timeout` at most.
	static func waitForBytes(
		_ path: String, offset: UInt64, _ text: String, timeout: Duration = .seconds(10)
	) async -> Bool {
		let expected = Data(text.utf8)
		let deadline = ContinuousClock.now + timeout
		while true {
			if (try? bytes(path, offset: offset, count: expected.count)) == expected { return true }
			if ContinuousClock.now >= deadline { return false }
			try? await Task.sleep(for: .milliseconds(200))
		}
	}

	/// A file of `size` bytes, every one `fill` (never zeros: APFS would keep zeros sparse,
	/// and a sparse source copies in no time), written in 1 MiB slices on its own thread.
	static func writeFile(_ path: String, size: Int, fill: UInt8 = 0xA5) async throws {
		let result: Result<Void, Error> = await offPool {
			do {
				let manager = FileManager.default
				try manager.createDirectory(
					atPath: (path as NSString).deletingLastPathComponent,
					withIntermediateDirectories: true)
				guard manager.createFile(atPath: path, contents: nil) else {
					throw LabError.specInvalid("can't create \(path)")
				}
				let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
				defer { try? handle.close() }
				let slice = Data(repeating: fill, count: 1 << 20)
				var left = size
				while left > 0 {
					let n = min(left, slice.count)
					try handle.write(contentsOf: n == slice.count ? slice : slice.prefix(n))
					left -= n
				}
				return .success(())
			} catch {
				return .failure(error)
			}
		}
		try result.get()
	}

	/// Every regular file under `dir` (relative path → sha256): "byte-identical" for a folder.
	static func dirDigest(_ dir: String) async throws -> [String: String] {
		var digest: [String: String] = [:]
		let manager = FileManager.default
		guard let walker = manager.enumerator(atPath: dir) else { return [:] }
		var files: [String] = []
		while let relative = walker.nextObject() as? String {
			var isDirectory: ObjCBool = false
			if manager.fileExists(atPath: dir + "/" + relative, isDirectory: &isDirectory),
				!isDirectory.boolValue {
				files.append(relative)
			}
		}
		for relative in files.sorted() { digest[relative] = try await sha256(dir + "/" + relative) }
		return digest
	}

	// MARK: Configs

	/// A VM's config file as JSON.
	static func config(atPath path: String) throws -> [String: Any] {
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		guard let object = try JSONSerialization.jsonObject(
			with: data, options: [.mutableContainers]) as? [String: Any] else {
			throw LabError.specInvalid("\(path) isn't a JSON object")
		}
		return object
	}

	static func config(_ scope: LabScope, _ vm: String) throws -> [String: Any] {
		try config(atPath: vmDir(scope, vm) + "/config")
	}

	/// A hand edit of the config file at `path`: every key the edit leaves alone stays as it
	/// was; the file is replaced in one rename.
	static func editConfig(atPath path: String, _ edit: (inout [String: Any]) -> Void) throws {
		var object = try config(atPath: path)
		edit(&object)
		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		try data.write(to: URL(fileURLWithPath: path), options: .atomic)
	}

	static func editConfig(
		_ scope: LabScope, _ vm: String, _ edit: (inout [String: Any]) -> Void
	) throws {
		try editConfig(atPath: vmDir(scope, vm) + "/config", edit)
	}

	/// Sets one start-policy switch in a config, keeping the policy's other keys.
	static func setPolicy(_ key: String, _ value: Bool, in object: inout [String: Any]) {
		var policy = object["startPolicy"] as? [String: Any] ?? [:]
		policy[key] = value
		object["startPolicy"] = policy
	}

	// MARK: Processes and sockets

	/// Six letters and digits: marks one test's writes apart from any other's.
	static func nonce() -> String {
		let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
		return String((0..<6).map { _ in alphabet.randomElement()! })
	}

	/// Whether something accepts on the socket at `path` (a connect, closed at once).
	static func isSocketLive(_ path: String) async -> Bool {
		await offPool {
			let fd = LabConsole.connectOnce(path)
			guard fd >= 0 else { return false }
			Darwin.close(fd)
			return true
		}
	}

	/// The pid of the process that accepts on `path`, from the connected socket's peer.
	static func socketPeer(_ path: String) async -> pid_t? {
		await offPool {
			let fd = LabConsole.connectOnce(path)
			guard fd >= 0 else { return nil }
			defer { Darwin.close(fd) }
			var pid: pid_t = 0
			var length = socklen_t(MemoryLayout<pid_t>.size)
			// LOCAL_PEERPID (0x002), as RPCConnection reads it.
			guard getsockopt(fd, SOL_LOCAL, 0x002, &pid, &length) == 0, pid > 0 else {
				return nil
			}
			return pid
		}
	}

	/// Polls until `path` accepts (or stops accepting), `timeout` at most.
	static func waitForSocket(
		_ path: String, live: Bool = true, timeout: Duration = .seconds(30)
	) async -> Bool {
		let deadline = ContinuousClock.now + timeout
		while true {
			if await isSocketLive(path) == live { return true }
			if ContinuousClock.now >= deadline { return false }
			try? await Task.sleep(for: .milliseconds(200))
		}
	}

	/// The vmhost processes whose arguments name `socketPath` — a count, never a kill list.
	static func vmhostPids(socketPath: String) async throws -> [pid_t] {
		let result = try await Subprocess.run("/bin/ps", ["-axww", "-o", "pid=,args="])
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "ps -axww", status: result.status, output: result.output)
		}
		return result.output.split(separator: "\n").compactMap { line in
			guard line.contains("MachmanVMHost"), line.contains(socketPath) else { return nil }
			return line.split(separator: " ").first.flatMap { pid_t($0) }
		}.sorted()
	}

	// MARK: Agent scopes

	/// Lab.withAgent with a step between the scope's creation and the agent's launch (a
	/// library symlinked onto another volume, a hand-made config): one scope at a time, the
	/// agent shut down on every path.
	static func withAgent<T>(
		_ options: LabAgent.Options = .init(),
		prepare: (LabScope) async throws -> Void = { _ in },
		_ body: (LabAgent) async throws -> T
	) async throws -> T {
		await LabGate.agents.enter()
		do {
			let scope = try LabScope.make()
			try await prepare(scope)
			let agent = try await LabAgent.launch(scope: scope, options: options)
			do {
				let result = try await body(agent)
				await agent.shutdown()
				await LabGate.agents.leave()
				return result
			} catch {
				await agent.shutdown()
				throw error
			}
		} catch {
			await LabGate.agents.leave()
			throw error
		}
	}

	/// The agent menu's Quit with VMs running, answered "Quit, Leave VMs Running" from the
	/// answers file (C-7) and asked over the control socket (C-8): the agent exits, its
	/// vmhosts stay.
	static func quitLeavingVMsRunning(_ agent: LabAgent) async throws {
		try agent.setAnswers(["agent.vmsStillRunning": "Quit, Leave VMs Running"])
		let mark = LabLog.mark()
		// The terminate can beat the reply out: EOF after a quit is fine.
		_ = try? await agent.control("quit userQuit")
		_ = try await LabLog.waitFor(
			SeamProbe.promptLine("agent.vmsStillRunning", "Quit, Leave VMs Running$"),
			after: mark, process: "MachmanAgent", timeout: .seconds(20))
		guard await agent.waitForExit(timeout: .seconds(30)) else {
			throw LabError.agentDidNotStart("the agent answered Quit but didn't exit in 30 s")
		}
	}

	/// SIGKILL of the agent the harness launched, and its exit.
	static func killAgent(_ agent: LabAgent) async throws {
		agent.kill(SIGKILL)
		guard await agent.waitForExit(timeout: .seconds(15)) else {
			throw LabError.agentDidNotStart("the agent outlived SIGKILL by 15 s")
		}
	}

	static func waitForExit(_ pid: pid_t, timeout: Duration = .seconds(30)) async -> Bool {
		await LabProcesses.waitForExit(pid, timeout: timeout)
	}

	/// SIGKILL of a vmhost whose pid came from its socket's peer, and its exit.
	static func killHost(_ pid: pid_t) async throws {
		LabProcesses.signal(pid, SIGKILL)
		guard await LabProcesses.waitForExit(pid, timeout: .seconds(15)) else {
			throw LabError.agentDidNotStart("vmhost \(pid) outlived SIGKILL by 15 s")
		}
	}
}
