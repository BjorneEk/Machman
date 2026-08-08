import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct RegistryRestrictionTests {

	@Test @MainActor func restrictedRegistrySeesOnlyItsVM() throws {
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				_ = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			}

			let full = VMRegistry()
			#expect(full.list().count == 2)

			let restricted = VMRegistry(only: "alpha")
			#expect(restricted.list().map(\.name) == ["alpha"])
			#expect(restricted.vm(named: "beta") == nil)
			#expect(throws: MachmanError.self) {
				_ = try restricted.create()
			}
		}
	}

	@Test @MainActor func reloadPicksUpOnDiskChanges() throws {
		try VMTestDir.withRedirectedDir {
			let name = "reload-vm"
			try VMConfig.createNewVMDirectory(name: name)
			_ = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)

			let registry = VMRegistry()
			#expect(registry.vm(named: name)?.config.cpuCount == 2)

			// Another process (a vmhost) edits the config file behind the registry's back.
			let other = try VMConfig.load(name: name)
			try other.setCPUCount(5)

			registry.reload(name: name)
			#expect(registry.vm(named: name)?.config.cpuCount == 5)
		}
	}
}
