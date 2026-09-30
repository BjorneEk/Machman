import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport

// Path resolution is what keeps a development build off the production VM library — there is no
// runtime guard any more, so these tests are the guard.
struct DataDirResolutionTests {
	// Each defaults domain is an ABSOLUTE PATH inside the run's scratch dir (CFPreferences takes
	// an absolute application id as a plist location), so nothing lands in the real
	// ~/Library/Preferences and none of these can be a real Machman domain.
	private func makeDefaults(_ name: String, dataDir: String? = nil) -> UserDefaults {
		let defaults = UserDefaults(
			suiteName: TestEnvironment.scratch + "defaults-\(name)-\(UUID().uuidString)")!
		if let dataDir = dataDir {
			defaults.set(dataDir, forKey: "MachmanDataDir")
		}
		return defaults
	}

	private var appSupport: String {
		NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
			.first ?? (NSHomeDirectory() + "/Library/Application Support")
	}

	// MARK: - Precedence

	@Test func envOverrideWinsOverDefaults() {
		let defaults = makeDefaults("machman-test-datadir-env", dataDir: "/tmp/from-defaults")
		let dir = MachmanPaths.dataDir(
			env: ["MACHMAN_DATA_DIR": "/tmp/from-env"], defaults: defaults)
		#expect(dir == "/tmp/from-env")
	}

	@Test func defaultsUsedWhenEnvAbsent() {
		let defaults = makeDefaults("machman-test-datadir-defaults", dataDir: "/tmp/from-defaults")
		let dir = MachmanPaths.dataDir(env: [:], defaults: defaults)
		#expect(dir == "/tmp/from-defaults")
	}

	@Test func emptyValuesAreTreatedAsUnset() {
		let defaults = makeDefaults("machman-test-datadir-empty", dataDir: "")
		let dir = MachmanPaths.dataDir(
			env: ["MACHMAN_DATA_DIR": "", "MACHMAN_SUITE_ID": "com.example.suite"],
			defaults: defaults)
		#expect(dir == appSupport + "/com.example.suite")
	}

	@Test func fallsBackToApplicationSupportUnderSuiteID() {
		let defaults = makeDefaults("machman-test-datadir-fallback")
		let dir = MachmanPaths.dataDir(
			env: ["MACHMAN_SUITE_ID": "com.example.suite"], defaults: defaults)
		#expect(dir == appSupport + "/com.example.suite")
		#expect(MachmanPaths.vmsDir(dataDir: dir) == dir + "/VMs")
	}

	// MARK: - Dev/production separation

	// The whole point of the suffix: two builds, two libraries, no overlap. If this ever fails a
	// development build is one launch away from writing to the production VMs.
	@Test func debugAndReleaseSuitesNeverShareALibrary() {
		let release = MachmanPaths.dataDir(
			env: ["MACHMAN_SUITE_ID": "com.gustaffranzen.Machman"], defaults: makeDefaults("m1"))
		let debug = MachmanPaths.dataDir(
			env: ["MACHMAN_SUITE_ID": "com.gustaffranzen.Machman.dev"], defaults: makeDefaults("m2"))
		#expect(release != debug)
		#expect(!debug.hasPrefix(release + "/"))   // nesting would put dev VMs inside production
	}

	@Test func suiteIdentifierPrefersEnv() {
		#expect(MachmanPaths.suiteIdentifier(env: ["MACHMAN_SUITE_ID": "com.example.x"])
			== "com.example.x")
		// A bare tool (no bundle id at all) must still resolve to something.
		#expect(!MachmanPaths.suiteIdentifier(env: [:]).isEmpty)
	}

	// Every Machman binary must land on ONE library. Helper bundle ids are the suite id plus a
	// known suffix, and stripping it is the only thing tying them together — Xcode drops custom
	// INFOPLIST_KEY_* settings, so a shared plist key is not available to do this job.
	@Test func helperBundleIDsCollapseToTheSameSuite() {
		let suite = "com.gustaffranzen.Machman.dev"
		for id in [suite, suite + ".agent", suite + ".vmhost", suite + ".tests", suite + ".uitests"] {
			#expect(MachmanPaths.suiteIdentifier(fromBundleID: id) == suite)
		}
		// A suffix that only looks like a helper must survive intact.
		#expect(MachmanPaths.suiteIdentifier(fromBundleID: "com.example.agentic")
			== "com.example.agentic")
	}

	// MARK: - Sockets

	// sun_path is 104 bytes. The VM name is hashed precisely so a user-chosen name can't
	// overflow it; assert that with a name far longer than anyone would type.
	@Test func vmSocketPathsStayWithinSunPath() {
		let runtime = MachmanPaths.runtimeDir(env: ["MACHMAN_SUITE_ID": "com.gustaffranzen.Machman.dev"])
		let absurd = String(repeating: "long-vm-name-", count: 20)
		for name in ["a", "Debian", absurd] {
			let path = MachmanPaths.vmSocketPath(vm: name, runtimeDir: runtime)
			#expect(path.utf8.count < 104, "socket path too long for sun_path: \(path)")
		}
		#expect(runtime.utf8.count + "/machman.sock".utf8.count < 104)
	}

	@Test func vmSocketHashIsStableAndDistinct() {
		let a = MachmanPaths.vmSocketPath(vm: "Debian", runtimeDir: "/tmp/r")
		#expect(a == MachmanPaths.vmSocketPath(vm: "Debian", runtimeDir: "/tmp/r"))
		#expect(a != MachmanPaths.vmSocketPath(vm: "Ubuntu", runtimeDir: "/tmp/r"))
	}

	// Sockets must not live in the VM library: it is relocatable, may be on a volume that can't
	// host a socket, and its depth is what pushes paths past sun_path.
	@Test func runtimeDirIsNotInsideTheDataDir() {
		let env = ["MACHMAN_SUITE_ID": "com.gustaffranzen.Machman.dev"]
		let data = MachmanPaths.dataDir(env: env, defaults: makeDefaults("machman-test-split"))
		let runtime = MachmanPaths.runtimeDir(env: env)
		#expect(!runtime.hasPrefix(data))
	}
}
