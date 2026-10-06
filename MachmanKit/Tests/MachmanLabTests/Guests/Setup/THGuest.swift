//
//  THGuest.swift
//  MachmanLabTests
//
//  A booted Guest Setup guest as the rows drive it: root (or a user) runs commands with no
//  terminal, a session types into a logged-in console, the VM's VMInfo carries the report.
//  TH.withGuest boots one for a test inside its own agent scope; THGuestScope shares one boot
//  across a suite of read-only rows (its tests never call Lab.withAgent: the gate that
//  serializes agent scopes is not reentrant).
//

import Foundation
import MachmanAPI
import MachmanDesktopCore
import Testing

protocol THGuest: AnyObject, Sendable {
	var kind: THGuestKind { get }
	var agent: LabAgent { get }
	/// The Machman VM whose VMInfo carries this guest's report (a BSD guest's carrier).
	var vm: THVM { get }
	/// The lab sshd playing the Mac (nil when the doctor refused a bridge listener).
	var mac: THMac? { get }
	/// The console root is logged in on (hvc2 in the prepared VZ images).
	var driver: LabConsole { get }

	/// `command` as root, or as `user` through a login shell: no terminal (stdin /dev/null,
	/// no controlling tty), stdout and stderr merged.
	func exec(_ command: String, user: String?, timeout: Duration) async throws
		-> (status: Int32, output: String)

	/// Root's shell on the driver as `user` (su -l) for `body`'s sessions, back to root after.
	func asUserShell<T>(_ user: String, _ body: () async throws -> T) async throws -> T

	/// A guest reboot (in place, or the VM stops and is started again); the driver logs in
	/// again and, with `remount`, the share is mounted again unless the guest mounted it.
	func reboot(remount: Bool) async throws

	/// Back to root's prompt on the driver after a row that failed half-way (an installer
	/// still asking, a user's shell): interrupts, leaves, and as a last resort boots again.
	func recoverDriver() async

	/// Stops and removes what the guest started; for every exit path.
	func shutdown() async
}

extension THGuest {
	func sh(_ command: String, user: String? = nil, timeout: Duration = .seconds(300))
		async throws -> (status: Int32, output: String) {
		try await exec(command, user: user, timeout: timeout)
	}

	/// sh, but a non-zero exit throws; returns the output.
	@discardableResult
	func check(_ command: String, user: String? = nil, timeout: Duration = .seconds(300))
		async throws -> String {
		let result = try await sh(command, user: user, timeout: timeout)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: (user.map { "[\($0)] " } ?? "") + command, status: result.status,
				output: result.output)
		}
		return result.output
	}

	/// A session on the driver console.
	func session() -> THConsoleSession { THConsoleSession(driver) }

	func reboot() async throws { try await reboot(remount: true) }

	/// The installer with `arguments`, escalated as `escalation` says, run by `user` (root when
	/// nil): exactly the line a person types.
	func install(
		_ arguments: String, user: String? = nil, escalation: GuestEscalation = .root,
		timeout: Duration = .seconds(600)
	) async throws -> (status: Int32, output: String) {
		let line = escalation.apply(GuestCommand(TH.installer + (arguments.isEmpty
			? "" : " " + arguments)))
		return try await sh(line, user: user, timeout: timeout)
	}

	/// The VM's setup report once lastReportAt is later than `since` (any report when nil).
	@discardableResult
	func waitForReport(newerThan since: Date?, timeout: Duration = .seconds(60)) async throws
		-> GuestSetupInfo {
		return try await LabStep.run(
			"\(vm.name): waiting ≤\(LabStep.format(timeout)) for a setup report"
		) {
			let deadline = ContinuousClock.now + timeout
			while true {
				if let setup = try await vm.info().setup, let at = setup.lastReportAt,
					since.map({ at > $0 }) ?? true {
					return setup
				}
				if ContinuousClock.now >= deadline {
					let last = try await vm.info().setup?.lastReportAt
					throw LabError.stateTimeout(
						vm: vm.name,
						wanted: "a report newer than \(since.map { "\($0)" } ?? "none")",
						last: "\(last.map { "\($0)" } ?? "none")")
				}
				try await Task.sleep(for: .milliseconds(500))
			}
		}
	}

	/// This VM's marker.
	func marker() throws -> String { try THGuestFiles.marker(vm) }

	/// The report's stamp now (nil before the first): a later report is newer than it. A
	/// test clock is no mark — the host's stamp may land in the same second as a Date().
	/// The host restamps only a report whose content changed (a boot's that says what the
	/// last run said leaves it): reportFileDate marks a write.
	func reportMark() async throws -> Date? { try await vm.info().setup?.lastReportAt }

	/// Polls the VM's VMInfo until `condition` holds.
	@discardableResult
	func waitForInfo(
		_ what: String, timeout: Duration = .seconds(60), _ condition: (VMInfo) -> Bool
	) async throws -> VMInfo {
		return try await LabStep.run(
			"\(vm.name): waiting ≤\(LabStep.format(timeout)) for \(what)"
		) {
			let deadline = ContinuousClock.now + timeout
			while true {
				let info = try await vm.info()
				if condition(info) { return info }
				if ContinuousClock.now >= deadline {
					throw LabError.stateTimeout(vm: vm.name, wanted: what, last: "not yet")
				}
				try await Task.sleep(for: .milliseconds(500))
			}
		}
	}

	/// When the guest last wrote report.env, by the host's file (nil while there is none).
	func reportFileDate() -> Date? {
		(try? FileManager.default.attributesOfItem(atPath: vm.reportFile))?[.modificationDate]
			as? Date
	}

	/// Waits until the guest writes report.env after `since` (the host's file date), then
	/// long enough for the vmhost's 2 s poll to ingest it.
	func waitForReportFile(newerThan since: Date?, timeout: Duration = .seconds(360))
		async throws {
		try await LabStep.run("\(vm.name): waiting ≤\(LabStep.format(timeout)) for report.env") {
			let deadline = ContinuousClock.now + timeout
			while true {
				if let now = reportFileDate(), since.map({ now > $0 }) ?? true { break }
				if ContinuousClock.now >= deadline {
					throw LabError.stateTimeout(
						vm: vm.name, wanted: "report.env written again",
						last: "\(String(describing: since))")
				}
				try await Task.sleep(for: .milliseconds(500))
			}
			try await Task.sleep(for: .seconds(5))
		}
	}

	/// Approves the guest's reverse key once its report offered one (as the inspector's
	/// button does: there is nothing to approve before).
	func approveReverse(timeout: Duration = .seconds(60)) async throws {
		try await LabStep.run(
			"\(vm.name): waiting ≤\(LabStep.format(timeout)) for a reverse key to approve"
		) {
			let deadline = ContinuousClock.now + timeout
			while try await vm.info().ssh?.reverseState != .pending {
				if ContinuousClock.now >= deadline {
					throw LabError.stateTimeout(
						vm: vm.name, wanted: "a reverse key to approve",
						last: "\(try await vm.info().ssh?.reverseState.rawValue ?? "none")")
				}
				try await Task.sleep(for: .milliseconds(500))
			}
			_ = try await agent.api.setSSH(
				vm: vm.name, integrationEnabled: nil, reverseApproved: true, alias: nil)
		}
	}
}

enum TH {
	/// The installer as every guide prints it: `sh /mnt/machman/share/GuestSetup/install.sh`.
	static var installer: String { GuestSetupInstallerInfo.runCommand() }
	static var installerPath: String {
		GuestPaths.share + "/" + GuestSetupInstallerInfo.directoryName + "/"
			+ GuestSetupInstallerInfo.scriptName
	}

	/// The run's TH scratch for host folders and staged files: <run>/th/<scope>/<name>.
	static func hostDir(_ agent: LabAgent, _ name: String) throws -> String {
		let dir = Lab.runDir + "/th/\(agent.scope.id)/\(name)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return dir
	}

	/// A booted `kind` guest for `body` in an agent scope of its own; everything it started is
	/// stopped on every path.
	static func withGuest<T>(
		_ kind: THGuestKind, _ options: THGuestOptions = .init(),
		_ body: (any THGuest) async throws -> T
	) async throws -> T {
		try await Lab.withAgent { agent in
			let guest = try await boot(kind, options, agent: agent)
			do {
				let result = try await body(guest)
				await guest.shutdown()
				return result
			} catch {
				await guest.shutdown()
				throw error
			}
		}
	}

	static func boot(_ kind: THGuestKind, _ options: THGuestOptions, agent: LabAgent)
		async throws -> any THGuest {
		if kind.isVZ, kind != .vzfreebsd {
			return try await THVZGuest.boot(kind, options, agent: agent)
		}
		if kind == .freebsd14 || kind == .freebsd15 {
			return try await THBSDGuest.boot(kind, options, agent: agent)
		}
		throw LabError.specInvalid("no TH boot for \(kind) yet")
	}

	static func log(_ text: String) { MachmanLogger.log(.log, "lab: th: \(text)") }

	/// `output` as one line of words: the installer folds its sentences at the terminal's
	/// width, so a sentence is looked for in this.
	static func unwrapped(_ output: String) -> String {
		output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
			.joined(separator: " ")
	}
}

/// How a TH guest is built.
struct THGuestOptions: Sendable {
	enum LabUser: Sendable {
		/// lab with NOPASSWD sudo and `permit nopass` doas.
		case nopasswd
		/// lab with password "lab" in the sudo group (sudo asks).
		case password
	}

	var name: String?
	/// A VZ guest's console ports (hvc2 is the lab's driver).
	var consoles = 3
	/// A QEMU BSD guest's virtio consoles and its carrier's console ports: the lab runner
	/// puts every port on one controller (ttyV0.<n>), Machman one device per port
	/// (ttyV<n>.0), so beyond one port the names the installer expects are not there.
	var bsdConsoles = 1
	var graphics = false
	var rosetta = false
	var network = true
	/// Host folders: tag → kind (nil = virtiofs), under the run's TH scratch.
	var mounts: [String: String?] = [:]
	var labUser = LabUser.nopasswd
	/// Mount the share as root right after boot (what the Linux guide's line does).
	var mountShare = true
}

/// The guest a THGuestScope suite shares.
enum THShared {
	@TaskLocal static var guest: (any THGuest)?

	static func require() throws -> any THGuest {
		try #require(guest, "no shared TH guest (the suite needs .thGuest(<kind>))")
	}

	/// A row on the shared guest: a row that throws half-way leaves the driver at root's
	/// prompt for the next one.
	static func row(_ body: (any THGuest) async throws -> Void) async throws {
		let g = try require()
		do {
			try await body(g)
		} catch {
			await g.recoverDriver()
			throw error
		}
	}
}

/// One agent scope and one booted guest for a whole suite of read-only rows.
struct THGuestScope: SuiteTrait, TestScoping {
	let kind: THGuestKind
	let options: THGuestOptions

	var isRecursive: Bool { false }

	func provideScope(
		for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
	) async throws {
		guard Lab.runs(.l3) else { return try await function() }
		try await TH.withGuest(kind, options) { guest in
			try await THShared.$guest.withValue(guest) { try await function() }
		}
	}
}

extension Trait where Self == THGuestScope {
	static func thGuest(_ kind: THGuestKind, _ options: THGuestOptions = .init()) -> Self {
		THGuestScope(kind: kind, options: options)
	}
}
