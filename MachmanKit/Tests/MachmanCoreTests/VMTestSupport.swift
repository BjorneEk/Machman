import Foundation
import MachmanTestSupport
@testable import MachmanCore

// machmanVMDir is a shared global and Swift Testing runs suites in parallel, so any test that
// redirects it must hold this lock for the whole redirect to avoid clobbering a parallel test.
// Sync-only ON PURPOSE: a blocking gate held across an await deadlocks the cooperative pool
// (measured) — test async surfaces outside the redirect, or extract a sync seam instead.
enum VMTestDir {
	private static let lock = NSLock()

	static func withRedirectedDir<T>(_ body: () throws -> T) rethrows -> T {
		lock.lock()
		defer { lock.unlock() }
		let original = machmanVMDir
		let originalSafe = machmanSafeDir
		// Backstop behind MachmanTestGuard: the lazily resolved globals must sit inside this
		// run's sandbox before anything is swapped (a test never sees a real library).
		precondition(
			original.hasPrefix(TestEnvironment.dataDir)
				&& originalSafe.hasPrefix(TestEnvironment.dataDir),
			"machmanVMDir/machmanSafeDir resolved outside the test sandbox: \(original)")
		let tmp = TestEnvironment.scratch + "vmdir-\(UUID().uuidString)"
		machmanVMDir = tmp
		// Both globals swap under the ONE lock, so no test can sweep another's shadows —
		// or worse, the real safe dir.
		machmanSafeDir = tmp + ".safe"
		defer {
			machmanVMDir = original
			machmanSafeDir = originalSafe
			try? FileManager.default.removeItem(atPath: tmp)
			try? FileManager.default.removeItem(atPath: tmp + ".safe")
		}
		return try body()
	}
}
