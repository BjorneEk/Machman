//
//  TFProcess.swift
//  MachmanLabTests
//
//  Process facts and signals for the engine rows. A signal goes only to a pid whose
//  executable is still a lab app (proc_pidpath names MachmanAgent.app or MachmanVMHost.app),
//  or an sshd-session under the lab sshd, so a pid the system recycled is never signalled;
//  a SIGSTOP is always paired with a SIGCONT in the caller's defer.
//

import Darwin
import Foundation
import MachmanTestSupport

enum TFProcess {
	/// The executable path of `pid`, or nil when it is gone.
	static func path(of pid: pid_t) -> String? {
		var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
		let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
		guard n > 0 else { return nil }
		return String(cString: buffer)
	}

	static func isVMHost(_ pid: pid_t) -> Bool {
		path(of: pid)?.contains("MachmanVMHost.app/") == true
	}

	static func isAgent(_ pid: pid_t) -> Bool {
		path(of: pid)?.contains("MachmanAgent.app/") == true
	}

	/// An sshd-session child of the lab sshd (`labSSHD`, from <run>/pids/sshd.pid).
	static func isLabSSHDSession(_ pid: pid_t, labSSHD: pid_t) async -> Bool {
		guard let path = path(of: pid), path.hasSuffix("/sshd-session") || path.hasSuffix("/sshd")
		else { return false }
		return (try? await descendants(of: labSSHD).contains(pid)) == true
	}

	/// SIGSTOP, only to a lab agent or vmhost; false (nothing sent) for any other pid.
	@discardableResult
	static func stop(_ pid: pid_t) -> Bool { signalLabApp(pid, SIGSTOP) }

	/// SIGCONT, under the same rule as stop.
	@discardableResult
	static func resume(_ pid: pid_t) -> Bool { signalLabApp(pid, SIGCONT) }

	/// SIGKILL, under the same rule as stop.
	@discardableResult
	static func killLabApp(_ pid: pid_t) -> Bool { signalLabApp(pid, SIGKILL) }

	private static func signalLabApp(_ pid: pid_t, _ sig: Int32) -> Bool {
		guard pid > 1, isVMHost(pid) || isAgent(pid) else { return false }
		return kill(pid, sig) == 0
	}

	struct Row: Sendable, Equatable {
		let pid: pid_t
		let ppid: pid_t
		let command: String
	}

	/// Every process `ps` lists, with its parent and argv.
	static func table() async throws -> [Row] {
		let result = try await Subprocess.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="])
		guard result.status == 0 else {
			throw LabError.commandFailed(command: "ps -ax", status: result.status, output: "")
		}
		return parse(result.output)
	}

	/// `ps -o pid=,ppid=,command=` output as rows (pure).
	static func parse(_ text: String) -> [Row] {
		text.split(separator: "\n").compactMap { line in
			let words = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
			guard words.count >= 2, let pid = pid_t(words[0]), let ppid = pid_t(words[1])
			else { return nil }
			return Row(pid: pid, ppid: ppid, command: words.count > 2 ? String(words[2]) : "")
		}
	}

	/// Pids whose argv contains `needle`.
	static func pids(argvContaining needle: String) async throws -> [pid_t] {
		try await table().filter { $0.command.contains(needle) }.map(\.pid)
	}

	/// Every descendant of `root` (children, their children, …), not `root` itself.
	static func descendants(of root: pid_t) async throws -> [pid_t] {
		descendants(of: root, in: try await table())
	}

	static func descendants(of root: pid_t, in rows: [Row]) -> [pid_t] {
		var found: [pid_t] = []
		var frontier: Set<pid_t> = [root]
		while !frontier.isEmpty {
			let next = rows.filter { frontier.contains($0.ppid) && !found.contains($0.pid) }
			found += next.map(\.pid)
			frontier = Set(next.map(\.pid))
		}
		return found
	}

	/// This process's physical footprint (what Activity Monitor's Memory column shows).
	static func footprintBytes() -> UInt64 {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(
			MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
		let status = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			}
		}
		return status == KERN_SUCCESS ? info.phys_footprint : 0
	}
}

/// The main actor's responsiveness: a task stamps the clock every 20 ms on the main actor,
/// and the largest gap between two stamps is how long the main actor was busy.
@MainActor
final class TFMainActorProbe {
	private var task: Task<Void, Never>?
	private var last: ContinuousClock.Instant?
	private var maxGap: Duration = .zero

	func start() {
		last = ContinuousClock.now
		maxGap = .zero
		task = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(20))
				self?.stamp()
			}
		}
	}

	private func stamp() {
		let now = ContinuousClock.now
		if let last { maxGap = max(maxGap, now - last) }
		last = now
	}

	/// Stops the probe and returns the largest gap it saw (the current one included).
	@discardableResult
	func stop() -> Duration {
		task?.cancel()
		task = nil
		stamp()
		return maxGap
	}
}
