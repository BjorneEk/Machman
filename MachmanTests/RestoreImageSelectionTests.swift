import Testing
import Foundation
@testable import Machman

struct RestoreImageSelectionTests {

	@Test func parsesVersions() {
		let full = MacInstaller.parseVersion("26.5.1")
		#expect(full?.majorVersion == 26)
		#expect(full?.minorVersion == 5)
		#expect(full?.patchVersion == 1)

		let short = MacInstaller.parseVersion("15.2")
		#expect(short?.majorVersion == 15)
		#expect(short?.patchVersion == 0)

		#expect(MacInstaller.parseVersion("garbage")?.majorVersion == nil)
	}

	@Test func comparesVersions() {
		let v15_2 = OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)
		let v15_5 = OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)
		let v26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
		#expect(MacInstaller.versionLess(v15_2, v15_5))
		#expect(MacInstaller.versionLess(v15_5, v26))
		#expect(MacInstaller.isVersion(v15_2, atMost: v15_2))
		#expect(!MacInstaller.isVersion(v26, atMost: v15_5))
	}

	@Test func picksNewestHostCompatible() throws {
		let json = """
		{ "firmwares": [
			{"version": "26.5.1", "buildid": "25F80",  "url": "https://u/a.ipsw", "filesize": 1},
			{"version": "15.5",   "buildid": "24F74",  "url": "https://u/b.ipsw", "filesize": 2},
			{"version": "15.2",   "buildid": "24C101", "url": "https://u/c.ipsw", "filesize": 3},
			{"version": "14.7.1", "buildid": "23H222", "url": "https://u/d.ipsw", "filesize": 4}
		]}
		""".data(using: .utf8)!
		let index = try JSONDecoder().decode(MacInstaller.RestoreImageIndex.self, from: json)

		let host15_5 = OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 1)
		#expect(MacInstaller.newestCompatible(in: index, host: host15_5)?.version == "15.5")

		let host15_3 = OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 0)
		#expect(MacInstaller.newestCompatible(in: index, host: host15_3)?.version == "15.2")

		let host27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
		#expect(MacInstaller.newestCompatible(in: index, host: host27)?.version == "26.5.1")

		let ancient = OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0)
		#expect(MacInstaller.newestCompatible(in: index, host: ancient)?.version == nil)
	}
}
