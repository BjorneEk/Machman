import Foundation
@testable import Machman

// machmanVMDir is a shared global and Swift Testing runs suites in parallel, so any test that
// redirects it must hold this lock for the whole redirect to avoid clobbering a parallel test.
enum VMTestDir {
	private static let lock = NSLock()

	static func withRedirectedDir<T>(_ body: () throws -> T) rethrows -> T {
		lock.lock()
		defer { lock.unlock() }
		let original = machmanVMDir
		let tmp = NSTemporaryDirectory() + "machman-test-\(UUID().uuidString)"
		machmanVMDir = tmp
		defer {
			machmanVMDir = original
			try? FileManager.default.removeItem(atPath: tmp)
		}
		return try body()
	}
}
