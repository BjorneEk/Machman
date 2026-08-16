//
//  EmbeddedScriptTests.swift
//  MachmanTests
//
//  The guest scripts are .sh sources embedded at build time (GuestScripts/*.sh) and are
//  parameterless — everything per-VM arrives through the machman.env the writer generates
//  beside them. Two things can silently break that contract: a shell dialect we do not
//  parse under, and a variable the script reads that nothing generates (which expands to
//  an empty string and fails deep inside a guest). Both are guarded here.
//

import Testing
import Foundation
@testable import MachmanCore

struct EmbeddedScriptTests {

	private static let scripts: [(name: String, script: EmbeddedScript)] = [
		("ssh-setup.sh", SSHSetupInstaller.script),
		("console-login.sh", ConsoleLoginInstaller.script),
	]

	@Test func scriptsAreEmbeddedAndVersioned() {
		for (name, script) in Self.scripts {
			#expect(script.text.hasPrefix("#!/bin/sh"), "\(name) lost its shebang")
			#expect(script.version > 0, "\(name) has no SCRIPT_VERSION line")
			// Parameterless: the writer's env file is the only per-VM channel.
			#expect(script.text.contains(GuestInstallerWriter.environmentFileName))
		}
	}

	// Guests run these under dash, busybox ash, FreeBSD sh, OpenBSD ksh and bash-as-sh.
	// We cannot install those here, but three local parsers with different heritage
	// (bash in POSIX mode, and ksh93, which is strict where bash is forgiving) catch the
	// dialect slips that would otherwise only surface inside a guest.
	@Test func scriptsParseUnderEveryLocalShell() throws {
		let parsers = [
			("/bin/sh", ["-n"]),
			("/bin/bash", ["--posix", "-n"]),
			("/bin/ksh", ["-n"]),
		]
		for (name, script) in Self.scripts {
			let url = FileManager.default.temporaryDirectory
				.appendingPathComponent("machman-\(UUID().uuidString)-\(name)")
			try script.text.write(to: url, atomically: true, encoding: .utf8)
			defer { try? FileManager.default.removeItem(at: url) }
			for (shell, flags) in parsers {
				guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
				let process = Process()
				process.executableURL = URL(fileURLWithPath: shell)
				process.arguments = flags + [url.path]
				process.standardError = FileHandle.nullDevice
				try process.run()
				process.waitUntilExit()
				#expect(process.terminationStatus == 0, "\(name) does not parse under \(shell)")
			}
		}
	}

	// Every UPPERCASE variable a script reads without ever assigning it must come from
	// somewhere: machman.env, or the guest's own environment. Anything else is drift —
	// a rename on one side of the seam that expands to "" in the guest.
	@Test @MainActor func scriptsOnlyReadVariablesSomethingProvides() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "drift")
			let vm = try VMConfig(name: "drift", memorySize: 1 << 30, cpuCount: 2)
			let provided: [String: Set<String>] = [
				"ssh-setup.sh": Set(try SSHSetupInstaller.environment(for: vm).keys),
				"console-login.sh": Set(try ConsoleLoginInstaller.environment(for: vm).keys),
			]
			// Set by the guest's own environment, or by an inlined awk program.
			let ambient: Set<String> = ["SUDO_USER", "NF"]
			for (name, script) in Self.scripts {
				let unresolved = Self.referenced(script.text)
					.subtracting(Self.assigned(script.text))
					.subtracting(provided[name] ?? [])
					.subtracting(ambient)
				#expect(unresolved.isEmpty, "\(name) reads unprovided \(unresolved.sorted())")
				// And the wiring is real: the script does read what the env carries.
				#expect(!Self.referenced(script.text)
					.intersection(provided[name] ?? []).isEmpty, "\(name) reads no env key")
			}
		}
	}

	// MARK: - Shell-source scanning (deliberately crude; false negatives beat false alarms)

	private static func matches(_ pattern: String, in text: String, group: Int) -> Set<String> {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
		let range = NSRange(text.startIndex..., in: text)
		var found: Set<String> = []
		for match in regex.matches(in: text, range: range) {
			guard let r = Range(match.range(at: group), in: text) else { continue }
			found.insert(String(text[r]))
		}
		return found
	}

	// $NAME, ${NAME}, ${NAME:-default}
	private static func referenced(_ text: String) -> Set<String> {
		matches(#"\$\{?([A-Z_][A-Z0-9_]*)"#, in: text, group: 1)
	}

	// NAME=…, for NAME in …, read -r NAME
	private static func assigned(_ text: String) -> Set<String> {
		matches(#"(?m)^[ \t]*([A-Z_][A-Z0-9_]*)="#, in: text, group: 1)
			.union(matches(#"for +([A-Z_][A-Z0-9_]*) +in"#, in: text, group: 1))
			.union(matches(#"read +-r +([A-Z_][A-Z0-9_]*)"#, in: text, group: 1))
	}
}
