import Foundation
@testable import MachmanCore

// machmanVMDir is a shared global and Swift Testing runs suites in parallel, so any test that
// redirects it must hold this lock for the whole redirect to avoid clobbering a parallel test.
enum VMTestDir {
	private static let lock = NSLock()

	static func withRedirectedDir<T>(_ body: () throws -> T) rethrows -> T {
		lock.lock()
		defer { lock.unlock() }
		let original = machmanVMDir
		let originalSafe = machmanSafeDir
		let tmp = NSTemporaryDirectory() + "machman-test-\(UUID().uuidString)"
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
