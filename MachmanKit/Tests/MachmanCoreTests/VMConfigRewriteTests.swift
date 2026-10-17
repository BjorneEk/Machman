//
//  VMConfigRewriteTests.swift
//  MachmanCoreTests
//
//  Q39: three paths rewrote a VM's config outside the registry with their own decoder and
//  encoder — a safe run's history going back, Save as New VM's hand-over, and its rollback —
//  bypassing load's rules (the folder names the VM, the migrations) and a save's (a resolved
//  alias suffix is stored). They go through VMConfig.rewrite(atDir:) now.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct VMConfigRewriteTests {
	// A config as an older build wrote it: no alias stored, and a name field from elsewhere
	// (the folder is the name).
	private func writeOlderVM(_ name: String, created: Date) throws {
		let template = "template-\(UUID().uuidString)"
		try VMConfig.createNewVMDirectory(name: template)
		let config = try VMConfig(name: template, memorySize: 1 << 30, cpuCount: 2)
		try VMConfig.deleteVMDirectory(name: template)
		config.created = created
		try VMConfig.createNewVMDirectory(name: name)
		try JSONEncoder().encode(config)
			.write(to: URL(fileURLWithPath: machmanVMDir + "/\(name)/config"))
	}

	private func storedFields(_ name: String) throws -> [String: Any] {
		let data = try Data(contentsOf: URL(fileURLWithPath: machmanVMDir + "/\(name)/config"))
		return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
	}

	@Test("Q39: rewrite keeps a stored alias suffix and an unknown boot mode, like a normal save")
	func rewriteKeepsWhatASaveKeeps() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let config = try VMConfig(name: "alpha", memorySize: 1 << 30, cpuCount: 2)
			var ssh = config.ssh ?? SSHConfig()
			ssh.alias = "alpha-2.machman"
			config.ssh = ssh
			try config.saveVMConfig()
			// A boot mode a newer Machman wrote, kept as it was.
			var fields = try storedFields("alpha")
			fields["boot"] = ["mode": "future", "detail": 7]
			try JSONSerialization.data(withJSONObject: fields)
				.write(to: URL(fileURLWithPath: machmanVMDir + "/alpha/config"))

			try VMConfig.rewrite(atDir: machmanVMDir + "/alpha") { $0.totalRuntimeSeconds = 42 }
			let loaded = try VMConfig.load(name: "alpha")
			#expect(loaded.totalRuntimeSeconds == 42)
			#expect(loaded.ssh?.alias == "alpha-2.machman")
			let boot = try #require(try storedFields("alpha")["boot"] as? [String: Any])
			#expect(boot["mode"] as? String == "future")
			#expect(boot["detail"] as? Int == 7)
		}
	}

	// Before: the shadow's history went back through a bare decode and encode, which kept the
	// file's stale name field and stored no suffix for a VM whose default alias collides.
	@Test(
		"""
		Q39: a safe run's stop saves the history like any save: the folder's name and a \
		resolved alias suffix
		""")
	func aSafeRunsHistoryIsSavedLikeAnySave() throws {
		try VMTestDir.withRedirectedDir {
			let older = Date(timeIntervalSince1970: 1_600_000_000)
			try writeOlderVM("dev copy", created: older)   // loses dev-copy.machman (A-1a-1)
			try writeOlderVM("dev-copy", created: older.addingTimeInterval(1))
			let shadowRoot = TestEnvironment.scratch + "shadow-\(UUID().uuidString)"
			try FileManager.default.createDirectory(
				atPath: shadowRoot + "/dev copy", withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: shadowRoot) }
			let shadow = try VMConfig.load(name: "dev copy")
			shadow.lastRan = Date(timeIntervalSince1970: 1_700_000_000)
			shadow.totalRuntimeSeconds = 100
			try JSONEncoder().encode(shadow)
				.write(to: URL(fileURLWithPath: shadowRoot + "/dev copy/config"))

			SafeRun.absorbShadowHistory(
				realDir: machmanVMDir + "/dev copy", shadowDir: shadowRoot + "/dev copy")
			let fields = try storedFields("dev copy")
			#expect(fields["name"] as? String == "dev copy")
			#expect((fields["ssh"] as? [String: Any])?["alias"] as? String
				== "dev-copy-2.machman")
			let absorbed = try VMConfig.load(name: "dev copy")
			#expect(absorbed.totalRuntimeSeconds == 100)
			#expect(absorbed.lastRan == shadow.lastRan)
		}
	}

	@Test(
		"""
		Q39: only VMConfig writes a VM config with the persistence coder (and the copier its \
		new folder's)
		""")
	func onlyVMConfigWritesAConfig() throws {
		let files = SourceScan.swiftFiles(under: "MachmanKit/Sources/MachmanCore")
		#expect(files.count > 40, "the scan found too few files")
		let found = try SourceScan.hits(#"\.prettyPrinted"#, in: files).filter {
			!$0.file.hasSuffix("/VMConfig.swift") && !$0.file.hasSuffix("/VMCopier.swift")
		}
		#expect(found.isEmpty, "rewrite through VMConfig.rewrite(atDir:): \(found)")
	}
}
