import Testing
import Foundation
@testable import MachmanCore

// Resolution precedence for the VM data dir: env var > user default > ~/.machman.
// Each test uses its own UserDefaults suite so parallel test execution can't interfere.
struct DataDirResolutionTests {
	private func makeDefaults(_ name: String, dataDir: String? = nil) -> UserDefaults {
		let defaults = UserDefaults(suiteName: name)!
		defaults.removePersistentDomain(forName: name)
		if let dataDir = dataDir {
			defaults.set(dataDir, forKey: "MachmanDataDir")
		}
		return defaults
	}

	@Test func envOverrideWinsOverDefaults() {
		let defaults = makeDefaults("machman-test-datadir-env", dataDir: "/tmp/from-defaults")
		defer { defaults.removePersistentDomain(forName: "machman-test-datadir-env") }
		let dir = resolveMachmanDataDir(
			env: ["MACHMAN_DATA_DIR": "/tmp/from-env"], defaults: defaults)
		#expect(dir == "/tmp/from-env")
	}

	@Test func defaultsUsedWhenEnvAbsent() {
		let defaults = makeDefaults("machman-test-datadir-defaults", dataDir: "/tmp/from-defaults")
		defer { defaults.removePersistentDomain(forName: "machman-test-datadir-defaults") }
		let dir = resolveMachmanDataDir(env: [:], defaults: defaults)
		#expect(dir == "/tmp/from-defaults")
	}

	@Test func emptyValuesAreTreatedAsUnset() {
		let defaults = makeDefaults("machman-test-datadir-empty", dataDir: "")
		defer { defaults.removePersistentDomain(forName: "machman-test-datadir-empty") }
		let dir = resolveMachmanDataDir(env: ["MACHMAN_DATA_DIR": ""], defaults: defaults)
		#expect(dir == NSHomeDirectory() + "/.machman")
	}

	@Test func fallsBackToHomeMachman() {
		let defaults = makeDefaults("machman-test-datadir-fallback")
		defer { defaults.removePersistentDomain(forName: "machman-test-datadir-fallback") }
		let dir = resolveMachmanDataDir(env: [:], defaults: defaults)
		#expect(dir == NSHomeDirectory() + "/.machman")
	}

	// The guard must never block test runs — the test host launches the real app first.
	@Test func guardIsInertUnderTests() {
		enforceDevDataDirGuard(resolved: NSHomeDirectory() + "/.machman")
	}

	// The scheme sets MACHMAN_DATA_DIR to $(SRCROOT)/.machman; if Xcode ever stopped
	// expanding build-settings macros in scheme env vars, the app would silently use a
	// literal "$(SRCROOT)" directory. Tolerates the var being absent (bare xcodebuild).
	@Test func schemeEnvVarExpandsIfSet() {
		guard let dir = ProcessInfo.processInfo.environment["MACHMAN_DATA_DIR"],
			!dir.isEmpty else {
			return
		}
		#expect(!dir.contains("$("))
		#expect(dir.hasPrefix("/"))
	}
}
