//
//  SafeRunFixture.swift
//  MachmanTests
//
//  A safe-run vmhost's registry with the exact shape promotion meets: the ORIGINAL VM in a
//  library, its shadow built by the real SafeRun.shadowRequest + VMCopier (safe disks
//  cloned, unsafe ones referenced), and a bare VMRuntime (no VZ) marking the shadow running
//  with what a start would have attached. Build it inside VMTestDir.withRedirectedDir: the
//  redirected machmanVMDir plays the run root, a sibling "-lib" folder the library (scratch,
//  removed with the run).
//

import Foundation
import MachmanAPI
@testable import MachmanCore

@MainActor
struct SafeRunFixture {
	let registry: VMRegistry
	let library: String
	let runRoot: String
	let name: String

	var originalDir: String { library + "/" + name }
	var shadowDir: String { runRoot + "/" + name }

	// `disks`: the original's entries; every storage entry gets a "<n>.raw" holding
	// "raw-<n>". `files`: extra files in the original's folder (isos, images).
	static func make(
		name: String = "alpha", disks: [VMDisk] = [], files: [String: Data] = [:],
		mac: String = "aa:bb:cc:dd:ee:99"
	) throws -> SafeRunFixture {
		let runRoot = machmanVMDir
		let library = runRoot + "-lib"
		let original = library + "/" + name
		let fm = FileManager.default
		try fm.createDirectory(atPath: runRoot, withIntermediateDirectories: true)
		try fm.createDirectory(atPath: original, withIntermediateDirectories: true)
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"seed","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		config.name = name
		config.disks = disks
		config.macAddress = mac
		try write(config, to: original)
		for disk in disks {
			if case .storage(let disk, _) = disk.kind {
				try Data("raw-\(disk)".utf8)
					.write(to: URL(fileURLWithPath: original + "/\(disk).raw"))
			}
		}
		for (file, data) in files {
			try data.write(to: URL(fileURLWithPath: original + "/" + file))
		}
		try VMCopier.copy(SafeRun.shadowRequest(
			config: config, sourceDir: original, runRoot: runRoot))
		let registry = VMRegistry(only: name, promotionLibrary: library)
		if let vm = registry.vm(named: name) {
			let runtime = VMRuntime(config: vm.config, events: registry.events)
			runtime.recordAttachedDisks()
			vm.runtime = runtime
		}
		return SafeRunFixture(registry: registry, library: library, runRoot: runRoot, name: name)
	}

	// The persistence coder, at an explicit folder — never saveVMConfig (the global dir).
	nonisolated static func write(_ config: VMConfig, to dir: String) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .prettyPrinted
		try encoder.encode(config).write(to: URL(fileURLWithPath: dir + "/config"))
	}

	nonisolated static func load(_ dir: String) throws -> VMConfig {
		try JSONDecoder().decode(
			VMConfig.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/config")))
	}

	func removeLibrary() {
		try? FileManager.default.removeItem(atPath: library)
	}
}
