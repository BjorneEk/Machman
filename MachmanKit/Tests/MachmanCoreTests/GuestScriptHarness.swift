//
//  GuestScriptHarness.swift
//  MachmanTests
//
//  Runs the guest setup script's own functions under every local POSIX shell: the assembled
//  modules minus the driver (90-main gives only its function definitions, everything before
//  its detection phase), from a payload laid out as Machman serves it — <dir>/GuestSetup with
//  the script and its machman.env, <dir>/GuestReport beside it — followed by a test body.
//  The body sees $D (the scratch dir) and may override any function (a `ps`, `systemctl` or
//  `have` stub) before calling the code under test. Nothing here needs root; a body points
//  the system paths it touches into $D. scripts/guest-regress runs the whole script as root.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

enum GuestScriptHarness {
	// macOS's /bin/sh (bash in POSIX mode), dash and ksh93: three dialects where present.
	static let shells = ["/bin/sh", "/bin/dash", "/bin/ksh"]
		.filter { FileManager.default.isExecutableFile(atPath: $0) }

	static let marker = "machman-0123456789ab"

	// The machman.env scripts/guest-regress serves; `env` overrides or adds keys.
	static let environment: [String: String] = [
		"VM_NAME": "regression-vm",
		"MARKER": marker,
		"REPORT_DIR_NAME": "GuestReport",
		"MOUNT_ROOT": "/mnt/machman/mounts",
		"SHARE_ROOT": "/mnt/machman/share",
		"SHARE_TAG": "host-share",
		"SHARE_HOST_PATH": "/Users/g/App Support/regression/share",
		"BOOT_MODE": "efi",
		"CONSOLE_COUNT": "2",
		"UART_COUNT": "0",
		"HOST_USER": "gustaf",
		"HOST_NAME": "Mac",
		"HOST_LOCAL": "mac.local",
	]

	// A fresh scratch dir for one probe (or several that share files: pass it to `run`).
	static func scratch() throws -> URL {
		let dir = TestEnvironment.scratchURL
			.appendingPathComponent("guestscript-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	// Runs `body` under `shell` (script arguments `args`) and returns its exit status and
	// merged stdout + stderr. Unattended: stdin is /dev/null and -y is implied.
	static func run(
		_ body: String, under shell: String, env: [String: String] = [:],
		args: [String] = [], in dir: URL? = nil
	) throws -> (status: Int32, out: String) {
		let dir = try dir ?? scratch()
		let fm = FileManager.default
		let payload = dir.appendingPathComponent("GuestSetup", isDirectory: true)
		try fm.createDirectory(at: payload, withIntermediateDirectories: true)
		try fm.createDirectory(
			at: dir.appendingPathComponent("GuestReport", isDirectory: true),
			withIntermediateDirectories: true)
		try GuestInstallerWriter.environmentFile(environment.merging(env) { $1 })
			.write(to: payload.appendingPathComponent("machman.env"),
				atomically: true, encoding: .utf8)

		var script = ""
		for part in GuestSetupScript.parts where part.name != "90-main" {
			script += String(decoding: part.bytes, as: UTF8.self)
			if !script.hasSuffix("\n") { script += "\n" }
		}
		script += try driverFunctions()
		script += "D=\(GuestInstallerWriter.shellQuoted(dir.path))\n" + body + "\n"
		let probe = payload.appendingPathComponent("probe.sh")
		try script.write(to: probe, atomically: true, encoding: .utf8)

		let process = Process()
		process.executableURL = URL(fileURLWithPath: shell)
		process.arguments = [probe.path] + args
		process.currentDirectoryURL = dir
		process.environment = [
			"PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
			"ASSUME_YES": "1", "NO_COLOR": "1", "TERM": "dumb",
		]
		process.standardInput = FileHandle.nullDevice
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		try process.run()
		// A probe that waits on something never coming must fail, not hang the suite.
		DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
			if process.isRunning { process.terminate() }
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return (process.terminationStatus, String(decoding: data, as: UTF8.self))
	}

	// 90-main up to its detection phase: the helpers the modules call (feature_selected,
	// plan_line, the uninstall's unmount pass), without running the driver.
	private static func driverFunctions() throws -> String {
		let main = try #require(GuestSetupScript.parts.first { $0.name == "90-main" })
		let text = String(decoding: main.bytes, as: UTF8.self)
		let phase = try #require(text.range(of: " detection ----\n"))
		let head = text[..<phase.lowerBound]
		let lineStart = head.lastIndex(of: "\n").map { head.index(after: $0) } ?? head.startIndex
		return String(text[..<lineStart])
	}
}
