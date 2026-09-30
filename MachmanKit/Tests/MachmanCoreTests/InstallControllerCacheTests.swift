import Testing
import Foundation
@testable import MachmanCore

struct InstallSessionCacheTests {

	@Test @MainActor func sessionIsCachedPerVM() throws {
		try VMTestDir.withRedirectedDir {
			let name = "cache-vm"
			try VMConfig.createNewVMDirectory(name: name)
			_ = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			let registry = VMRegistry()

			let vm = try #require(registry.vm(named: name))
			let first = registry.installSession(for: vm)
			let second = registry.installSession(for: vm)
			#expect(first === second)
		}
	}
}
