//
//  THReadOnlyTests.swift
//  MachmanLabTests
//
//  L3 — the installer's rows that leave the guest as it was (help, version, dry run, the
//  interactive menu answered q), on one booted guest per OS. The row bodies live in
//  THReadOnlyRows so every OS's suite runs the same checks.
//

import Foundation
import MachmanAPI
import Testing

enum THReadOnlyRows {
	/// S1: --help and --version exit 0; help names the VM, version names the script version
	/// and this VM's marker.
	static func s1(_ g: any THGuest) async throws {
		let name = try await g.vm.info().name
		let help = try await g.sh("\(TH.installer) --help")
		#expect(help.status == 0, "\(help.output)")
		#expect(help.output.contains("Machman guest setup for \"\(name)\""), "\(help.output)")
		let version = try await g.sh("\(TH.installer) --version")
		#expect(version.status == 0, "\(version.output)")
		let current = try await g.vm.info().setup?.currentScriptVersion ?? 6
		#expect(version.output == "machman guest setup v\(current) (\(try g.marker()))")
	}
}

// L3 — the installer on the prepared Debian guest under VZ.
@Suite(
	"L3 Guest Setup — Debian read-only rows", .serialized, .enabled(if: Lab.runs(.l3)),
	.thGuest(.debian))
struct THReadOnlyDebianTests {
	@Test("S1: install.sh --help and --version exit 0 and name the VM")
	func s1() async throws { try await THReadOnlyRows.s1(try THShared.require()) }
}
