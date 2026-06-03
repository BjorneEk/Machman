import Testing
import Foundation
import Virtualization
@testable import Machman

struct MACAddressTests {

	@Test func macIsGeneratedAtCreationAndStable() throws {
		try VMTestDir.withRedirectedDir {
			let name = "mac-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			let mac = try #require(cfg.macAddress)              // assigned at creation
			#expect(VZMACAddress(string: mac) != nil)
			#expect(cfg.getOrCreateMACAddress().string == mac)  // backstop returns the same one

			let reloaded = try VMConfig(name: name)             // survives a save/load cycle
			#expect(reloaded.macAddress == mac)
		}
	}

	@Test func legacyConfigGainsMACOnLoad() throws {
		try VMTestDir.withRedirectedDir {
			let name = "legacy-mac-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			cfg.macAddress = nil                                // simulate a legacy config
			try cfg.saveVMConfig()

			let migrated = try VMConfig(name: name)
			let mac = try #require(migrated.macAddress)         // migration assigned one
			#expect(VZMACAddress(string: mac) != nil)

			let again = try VMConfig(name: name)                // and persisted it
			#expect(again.macAddress == mac)
		}
	}

	@Test func generatedMacIsParseable() {
		let mac = VZMACAddress.randomLocallyAdministered()
		#expect(VZMACAddress(string: mac.string) != nil)
	}
}
