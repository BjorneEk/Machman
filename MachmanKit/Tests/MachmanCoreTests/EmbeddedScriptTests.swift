//
//  EmbeddedScriptTests.swift
//  MachmanTests
//
//  The guest-setup installer is assembled at payload-write time from .sh modules
//  embedded at build time (GuestScripts/setup/*.sh) and is parameterless — everything
//  per-VM arrives through the machman.env the writer generates beside it. Three things
//  can silently break that contract: a module missing from (or doubled in) the assembly,
//  a shell dialect we do not parse under, and a variable the script reads that nothing
//  generates (which expands to an empty string and fails deep inside a guest).
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct EmbeddedScriptTests {

	// The unified installer is assembled from modules; a forgotten Package.swift entry or
	// a doubled part must fail here, never in a guest.
	@Test func assembledGuestSetupIsWhole() {
		let text = GuestSetupScript.assembled.text
		#expect(text.hasPrefix("#!/bin/sh"))
		#expect(GuestSetupScript.assembled.version == 5)
		#expect(text.contains(GuestInstallerWriter.environmentFileName))
		for part in GuestSetupScript.parts {
			let marker = GuestSetupScript.marker(for: part.name)
			let hits = text.components(separatedBy: marker).count - 1
			#expect(hits == 1, "\(part.name) marker appears \(hits) times")
		}
		// Exactly one shebang LINE and one version declaration survive assembly (the
		// boot-script writers legitimately carry "#!/bin/sh" inside printf strings).
		#expect(!text.contains("\n#!/bin/sh\n"))
		#expect(text.components(separatedBy: "\nSCRIPT_VERSION=").count == 2)
	}

	// S16: the dev-loop assembler (scripts/guest-regress, shellcheck) builds exactly the bytes
	// the app ships, so a line number from dist/install.sh is the guest's line number — and
	// both take the same modules: a part missing from Package.swift fails here.
	@Test func assembleShMatchesTheSwiftAssembly() throws {
		let here = URL(fileURLWithPath: #filePath)
		let assembler = here.deletingLastPathComponent()
			.appendingPathComponent("../../Sources/MachmanCore/GuestScripts/assemble.sh")
			.standardizedFileURL
		let out = TestEnvironment.scratchURL
			.appendingPathComponent("assemble-\(UUID().uuidString)/install.sh")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = [assembler.path, out.path]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		try process.run()
		process.waitUntilExit()
		#expect(process.terminationStatus == 0)
		let shipped = Data(GuestSetupScript.assembled.text.utf8)
		let assembled = try Data(contentsOf: out)
		#expect(assembled == shipped, """
			assemble.sh: \(assembled.count) bytes, the app: \(shipped.count) bytes
			""")
		let setup = assembler.deletingLastPathComponent().appendingPathComponent("setup")
		let modules = try FileManager.default.contentsOfDirectory(atPath: setup.path)
			.filter { $0.range(of: #"^[0-9]{2}-.*\.sh$"#, options: .regularExpression) != nil }
			.map { String($0.dropLast(3)) }
			.sorted()
		#expect(modules == GuestSetupScript.parts.map(\.name))
	}

	// Guests run this under dash, busybox ash, FreeBSD sh, OpenBSD ksh and bash-as-sh.
	// We cannot install those here, but three local parsers with different heritage
	// (bash in POSIX mode, and ksh93, which is strict where bash is forgiving) catch the
	// dialect slips that would otherwise only surface inside a guest.
	@Test func assembledScriptParsesUnderEveryLocalShell() throws {
		let parsers = [
			("/bin/sh", ["-n"]),
			("/bin/bash", ["--posix", "-n"]),
			("/bin/ksh", ["-n"]),
		]
		let url = TestEnvironment.scratchURL
			.appendingPathComponent("machman-\(UUID().uuidString)-guest-setup.sh")
		try GuestSetupScript.assembled.text.write(to: url, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: url) }
		for (shell, flags) in parsers {
			guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
			let process = Process()
			process.executableURL = URL(fileURLWithPath: shell)
			process.arguments = flags + [url.path]
			process.standardError = FileHandle.nullDevice
			try process.run()
			process.waitUntilExit()
			#expect(process.terminationStatus == 0, "does not parse under \(shell)")
		}
	}

	// Every UPPERCASE variable the script reads without ever assigning it must come from
	// somewhere: machman.env, or the guest's own environment. Anything else is drift —
	// a rename on one side of the seam that expands to "" in the guest.
	@Test @MainActor func scriptOnlyReadsVariablesSomethingProvides() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "drift")
			let vm = try VMConfig(name: "drift", memorySize: 1 << 30, cpuCount: 2)
			let provided = Set(try GuestSetupInstaller.environment(for: vm).keys)
			// Set by the guest's own environment (or by sudo/doas/ssh), never by us.
			let ambient: Set<String> = [
				"SUDO_USER", "DOAS_USER", "TERM", "NO_COLOR", "COLORTERM", "COLUMNS",
				"LANG", "LC_ALL", "LC_CTYPE", "IFS", "CDPATH", "SSH_TTY", "SSH_CONNECTION",
			]
			let source = GuestSetupScript.assembled.text
			let unresolved = Self.referenced(source)
				.subtracting(Self.assigned(source))
				.subtracting(provided)
				.subtracting(ambient)
			#expect(unresolved.isEmpty, "script reads unprovided \(unresolved.sorted())")
			// And the wiring is real: the script does read what the env carries.
			#expect(!Self.referenced(source).intersection(provided).isEmpty)
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

	// $NAME, ${NAME}, ${NAME:-default}. The lookahead keeps the scanner off the
	// lowercase-with-leading-underscore temporaries the scripts use inside functions.
	private static func referenced(_ text: String) -> Set<String> {
		matches(#"\$\{?([A-Z_][A-Z0-9_]*)(?![a-z])"#, in: text, group: 1)
	}

	// NAME= at the start of a command (line start, or after ; & | or a case-branch's
	// paren), the : "${NAME:=default}" idiom, for NAME in …, and read -r NAME.
	private static func assigned(_ text: String) -> Set<String> {
		matches(#"(?m)^[ \t]*([A-Z_][A-Z0-9_]*)="#, in: text, group: 1)
			.union(matches(#"[;&|)] *([A-Z_][A-Z0-9_]*)="#, in: text, group: 1))
			.union(matches(#"\$\{([A-Z_][A-Z0-9_]*):="#, in: text, group: 1))
			.union(matches(#"for +([A-Z_][A-Z0-9_]*) +in"#, in: text, group: 1))
			.union(matches(#"read +-r +([A-Z_][A-Z0-9_]*)"#, in: text, group: 1))
	}
}
