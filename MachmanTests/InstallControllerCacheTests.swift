import Testing
import Foundation
@testable import Machman

struct InstallControllerCacheTests {

	@Test @MainActor func controllerIsCachedPerVM() throws {
		try VMTestDir.withRedirectedDir {
			let name = "cache-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let vm = VirtualMachine(config: try VMConfig(name: name, memorySize: 2048, cpuCount: 2))
			let viewModel = VMListViewModel()

			let first = viewModel.installController(for: vm)
			let second = viewModel.installController(for: vm)
			#expect(first === second)
		}
	}
}
