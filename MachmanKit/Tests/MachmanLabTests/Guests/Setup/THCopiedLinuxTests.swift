//
//  THCopiedLinuxTests.swift
//  MachmanLabTests
//
//  L3 — the Linux commands the inspectors and guides offer to copy, run exactly as
//  GuestSetupCommands builds them: the share's run and mount lines as a user whose sudo asks
//  for a password, and the Rosetta guide's mount and register lines on Debian (systemd mounts
//  binfmt_misc) and Alpine (OpenRC does not), proven by an x86-64 binary that runs.
//

import Foundation
import MachmanAPI
import MachmanDesktopCore
import MachmanTestSupport
import Testing

/// A minimal static x86-64 Linux ELF: one PT_LOAD, write(1, "TH-X86-OK\n"), exit(0).
enum THX86 {
	static let output = "TH-X86-OK"

	static var bytes: [UInt8] {
		let base: UInt64 = 0x400000
		let headers = 64 + 56
		let code: [UInt8] = [
			0xB8, 0x01, 0x00, 0x00, 0x00,               // mov eax, 1 (write)
			0xBF, 0x01, 0x00, 0x00, 0x00,               // mov edi, 1
			0x48, 0x8D, 0x35, 0x10, 0x00, 0x00, 0x00,   // lea rsi, [rip + 16] (the text)
			0xBA, 0x0A, 0x00, 0x00, 0x00,               // mov edx, 10
			0x0F, 0x05,                                 // syscall
			0xB8, 0x3C, 0x00, 0x00, 0x00,               // mov eax, 60 (exit)
			0x31, 0xFF,                                 // xor edi, edi
			0x0F, 0x05,                                 // syscall
		] + Array("\(output)\n".utf8)
		let size = UInt64(headers + code.count)
		func le(_ value: UInt64, _ count: Int) -> [UInt8] {
			(0..<count).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
		}
		var elf: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
		elf += le(2, 2) + le(0x3E, 2) + le(1, 4)              // EXEC, x86-64, version 1
		elf += le(base + UInt64(headers), 8) + le(64, 8) + le(0, 8)   // entry, phoff, shoff
		elf += le(0, 4) + le(64, 2) + le(56, 2) + le(1, 2)   // flags, ehsize, phentsize, phnum
		elf += le(0, 2) + le(0, 2) + le(0, 2)                // shentsize, shnum, shstrndx
		elf += le(1, 4) + le(5, 4) + le(0, 8)                // PT_LOAD, R+X, offset 0
		elf += le(base, 8) + le(base, 8) + le(size, 8) + le(size, 8) + le(0x1000, 8)
		return elf + code
	}

	/// The binary in `dir` (a virtiofs host folder), checked by the host's file(1).
	static func drop(into dir: String) async throws -> String {
		let path = dir + "/th-x86"
		try Data(bytes).write(to: URL(fileURLWithPath: path))
		chmod(path, 0o755)
		let file = try await Subprocess.run("/usr/bin/file", ["-b", path], timeout: 30)
		#expect(file.output.contains("ELF 64-bit LSB executable, x86-64"), "\(file.output)")
		return path
	}
}

enum THRosetta {
	static let entry = "/proc/sys/fs/binfmt_misc/rosetta"

	/// Whether this Mac has Rosetta (the lab never installs it: that shows a system prompt).
	static func installed(_ agent: LabAgent) async throws -> Bool {
		try await agent.api.hostCapabilities().rosettaAvailability
			== RosettaAvailability.installed
	}

	static let skip = "Rosetta isn't installed on this Mac — the lab never installs it"

	/// The x86 binary dropped into the "th" host folder, copied to /tmp in the guest.
	static func stage(_ g: any THGuest) async throws -> String {
		_ = try await THX86.drop(into: try TH.hostDir(g.agent, "th"))
		try await g.check("cp \(GuestPaths.share)/th/th-x86 /tmp/th-x86 && chmod 755 /tmp/th-x86")
		return "/tmp/th-x86"
	}
}

// L3 — the copied Linux commands on Debian and Alpine.
@Suite("L3 Guest Setup — copied Linux commands", .serialized, .enabled(if: Lab.runs(.l3)))
struct THCopiedLinuxTests {
	@Test("W3-29: the copied run and mount lines work for a normal user via sudo")
	func copiedLinesWithSudoPassword() async throws {
		var options = THGuestOptions()
		options.labUser = .password
		try await TH.withGuest(.debian, options) { g in
			let root = try await g.install("-y --automount-virtiofs")
			#expect(root.status == 0, "\(root.output)")
			let run = GuestSetupCommands.run(.linux, shareMounted: true)
			let mount = GuestSetupCommands.mountShare(.linux)
			let mountAndRun = GuestSetupCommands.run(.linux, shareMounted: false)
			#expect(run == "sudo " + TH.installer)
			#expect(mountAndRun.hasPrefix(mount + " && sudo "))
			try await g.asUserShell("lab") {
				let first = g.session()
				try first.start(run)
				let asked = try await first.drive(proceed: "q", password: "lab")
				#expect(asked.status == 3, "\(asked.output)")
				#expect(asked.kinds.first == .password, "sudo asked for lab's password first")
				#expect(asked.kinds.contains(.proceed), "\(asked.output)")
			}
			try await g.check("umount \(GuestPaths.share)")
			try await g.asUserShell("lab") {
				let mounting = g.session()
				try mounting.start(mount)
				let mounted = try await mounting.drive(password: "lab")
				#expect(mounted.status == 0, "\(mounted.output)")
			}
			let table = try await g.check("mount")
			#expect(table.contains("host-share on \(GuestPaths.share)"), "\(table)")
			try await g.check("umount \(GuestPaths.share)")
			try await g.asUserShell("lab") {
				let both = g.session()
				try both.start(mountAndRun)
				let asked = try await both.drive(proceed: "q", password: "lab")
				#expect(asked.status == 3, "\(asked.output)")
				#expect(asked.kinds.contains(.proceed), "the installer ran: \(asked.output)")
			}
		}
	}

	@Test("W4-3: the Rosetta guide's two commands register Rosetta on Debian")
	func rosettaOnDebian() async throws {
		var options = THGuestOptions()
		options.rosetta = true
		options.mounts = ["th": nil]
		try await TH.withGuest(.debian, options) { g in
			guard try await THRosetta.installed(g.agent) else {
				try Test.cancel(Comment(rawValue: THRosetta.skip))
			}
			let binary = try await THRosetta.stage(g)
			for line in [GuestSetupCommands.rosettaMount(.sudo),
				GuestSetupCommands.rosettaRegister(.sudo)] {
				let result = try await g.sh(line, user: "lab")
				#expect(result.status == 0, "\(line):\n\(result.output)")
			}
			let entry = try await g.check("cat \(THRosetta.entry)")
			#expect(entry.contains("enabled"), "\(entry)")
			#expect(entry.contains("interpreter /media/rosetta/rosetta"), "\(entry)")
			#expect(entry.contains("flags: OCF"), "\(entry)")
			#expect(try await g.check(binary) == THX86.output)
		}
	}

	@Test("W4-31: on Alpine the binfmt_misc mount line makes the register line work")
	func rosettaOnAlpine() async throws {
		var options = THGuestOptions()
		options.rosetta = true
		options.mounts = ["th": nil]
		try await TH.withGuest(.alpine, options) { g in
			guard try await THRosetta.installed(g.agent) else {
				try Test.cancel(Comment(rawValue: THRosetta.skip))
			}
			let binary = try await THRosetta.stage(g)
			let rootLines = [
				GuestSetupCommands.rosettaMount(.root), GuestSetupCommands.rosettaRegister(.root),
				GuestSetupCommands.binfmtMiscMount(.root),
			]
			for line in rootLines {
				#expect(!line.contains("sudo") && !line.contains("doas"), "\(line)")
			}
			#expect(try await g.sh(rootLines[0]).status == 0)
			var register = try await g.sh(rootLines[1])
			if register.status != 0 {
				#expect(register.output.contains("No such file or directory"),
					"\(register.output)")
				#expect(try await g.sh(rootLines[2]).status == 0)
				register = try await g.sh(rootLines[1])
			}
			#expect(register.status == 0, "\(register.output)")
			#expect(try await g.check("cat \(THRosetta.entry)").contains("enabled"))

			// Again as lab with doas: every escalated command says doas.
			try await g.check("echo -1 > \(THRosetta.entry) && umount /media/rosetta")
			let doasLines = [GuestSetupCommands.rosettaMount(.doas),
				GuestSetupCommands.rosettaRegister(.doas)]
			for line in doasLines {
				#expect(line.contains("doas ") && !line.contains("sudo"), "\(line)")
				let result = try await g.sh(line, user: "lab")
				#expect(result.status == 0, "\(line):\n\(result.output)")
			}
			#expect(try await g.check("cat \(THRosetta.entry)").contains("enabled"))
			#expect(try await g.check(binary) == THX86.output)
		}
	}
}
