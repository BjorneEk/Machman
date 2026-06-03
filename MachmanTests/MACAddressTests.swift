import Testing
import Foundation
import Virtualization
@testable import Machman

struct MACAddressTests {

	@Test func macIsGeneratedOnceAndPersists() throws {
		try VMTestDir.withRedirectedDir {
			let name = "mac-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			#expect(cfg.macAddress == nil)

			let first = cfg.getOrCreateMACAddress()
			#expect(cfg.macAddress == first.string)       // generated value is persisted in-model
			let second = cfg.getOrCreateMACAddress()
			#expect(second.string == first.string)        // stable across calls

			let reloaded = try VMConfig(name: name)        // and across a save/load cycle
			#expect(reloaded.macAddress == first.string)
			#expect(reloaded.getOrCreateMACAddress().string == first.string)
		}
	}

	@Test func generatedMacIsParseable() {
		let mac = VZMACAddress.randomLocallyAdministered()
		#expect(VZMACAddress(string: mac.string) != nil)
	}
}
