//
//  LaunchAgentManager.swift
//  MachmanCore
//
//  Per-VM launchd agents: one plist per autostarting VM, pointing straight at the vmhost
//  executable with `--autostart`, so the VM comes up at login with no daemon involved.
//
//  Install is write-plist-ONLY — bootstrapping a RunAtLoad job would boot the VM on the
//  spot; launchd picks the file up at the next login. Removal boots the job out only when
//  the caller allows it AND no live vmhost owns the VM's socket (a bootout SIGTERMs the
//  job — never acceptable while it is running a guest).
//
//  Paths are injected so tests run against throwaway directories by construction; the
//  daemon builds the real thing with `live()`.
//

import Foundation
import MachmanAPI

public struct LaunchAgentManager {
	let suiteID: String
	let vmhostExecutablePath: String
	let vmsDir: String
	let runtimeDir: String
	let agentsDir: String

	// nil when no vmhost app can be located (broken install). The daemon treats that as
	// "toggles persist, agents aren't written" and logs once.
	@MainActor
	public static func live() -> LaunchAgentManager? {
		guard let vmhost = VMHostLocator.locate() else { return nil }
		return LaunchAgentManager(
			suiteID: MachmanPaths.suiteIdentifier(),
			vmhostExecutablePath: vmhost.executableURL.path,
			vmsDir: machmanVMDir,
			runtimeDir: machmanRuntimeDir,
			agentsDir: NSHomeDirectory() + "/Library/LaunchAgents")
	}

	// `.vm.` can never collide with the helper bundle ids (`.agent`, `.vmhost`, …).
	private static let labelSafeCharacters =
		Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

	// `<suite>.vm.<name>` when the name is launchd- and filename-safe; otherwise a
	// deterministic hash fallback, so remove() always recomputes the same label the
	// install wrote and hostile names never strand a plist.
	func label(for name: String) -> String {
		let safe = !name.isEmpty && name.count <= 64
			&& name.allSatisfy { Self.labelSafeCharacters.contains($0) }
		return safe
			? "\(suiteID).vm.\(name)"
			: "\(suiteID).vm.h\(MachmanPaths.shortHash(name))"
	}

	func plistFileName(for name: String) -> String {
		label(for: name) + ".plist"
	}

	func plistPath(for name: String) -> String {
		agentsDir + "/" + plistFileName(for: name)
	}

	// Pure — this IS the contract the manual autostart matrix exercises. No
	// EnvironmentVariables on purpose: the vmhost self-identifies from its bundle id, and
	// the socket's parent directory is created by MachmanServer.start at serve time.
	func plistDictionary(for name: String) -> [String: Any] {
		[
			"Label": label(for: name),
			"ProgramArguments": [
				vmhostExecutablePath,
				"--data-dir", vmsDir,
				"--vm", name,
				"--socket", MachmanPaths.vmSocketPath(vm: name, runtimeDir: runtimeDir),
				"--autostart",
			],
			"RunAtLoad": true,
			"KeepAlive": false,
			"LimitLoadToSessionType": "Aqua",
		]
	}

	func install(vm name: String) throws {
		_ = try installIfChanged(vm: name)
	}

	// Returns whether it wrote — the self-heal pass logs rewrites and skips the rest.
	@discardableResult
	func installIfChanged(vm name: String) throws -> Bool {
		let expected = try PropertyListSerialization.data(
			fromPropertyList: plistDictionary(for: name), format: .xml, options: 0)
		let path = plistPath(for: name)
		if let current = FileManager.default.contents(atPath: path), current == expected {
			return false
		}
		ensureDirectory(agentsDir)
		try expected.write(to: URL(fileURLWithPath: path), options: .atomic)
		return true
	}

	func remove(vm name: String, canBootout: Bool) {
		let path = plistPath(for: name)
		let existed = FileManager.default.fileExists(atPath: path)
		try? FileManager.default.removeItem(atPath: path)
		guard existed, canBootout else { return }
		// launchd may still hold the job loaded from login. A live socket means it is
		// running the guest right now — leave it; the plist is gone, so this was the last
		// login it autostarts.
		let socketPath = MachmanPaths.vmSocketPath(vm: name, runtimeDir: runtimeDir)
		guard !UDSListener.isLive(path: socketPath) else { return }
		bootout(label: label(for: name))
	}

	// Fire-and-forget: never waitUntilExit on the actor. Nonzero exit is the healthy case
	// ("No such process" — nothing was loaded).
	private func bootout(label: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
		process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
		process.terminationHandler = { finished in
			if finished.terminationStatus != 0 {
				MachmanLogger.log(.log,
					"launchctl bootout \(label) exited \(finished.terminationStatus)")
			}
		}
		do {
			try process.run()
		} catch {
			MachmanLogger.log(.passiveError, "cannot run launchctl bootout: \(error)")
		}
	}
}
