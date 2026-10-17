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
		let originalScripts = machmanSetupScriptsDir
		// Backstop behind MachmanTestGuard: the lazily resolved globals must sit inside this
		// run's sandbox before anything is swapped (a test never sees a real library).
		precondition(
			original.hasPrefix(TestEnvironment.dataDir)
				&& originalSafe.hasPrefix(TestEnvironment.dataDir)
				&& originalScripts.hasPrefix(TestEnvironment.dataDir),
			"machmanVMDir/machmanSafeDir resolved outside the test sandbox: \(original)")
		let tmp = TestEnvironment.scratch + "vmdir-\(UUID().uuidString)"
		machmanVMDir = tmp
		// The globals swap under the ONE lock, so no test can sweep another's shadows — or
		// worse, the real safe dir — or serve another's Guest Setup scripts.
		machmanSafeDir = tmp + ".safe"
		machmanSetupScriptsDir = tmp + ".scripts"
		defer {
			machmanVMDir = original
			machmanSafeDir = originalSafe
			machmanSetupScriptsDir = originalScripts
			try? FileManager.default.removeItem(atPath: tmp)
			try? FileManager.default.removeItem(atPath: tmp + ".safe")
			try? FileManager.default.removeItem(atPath: tmp + ".scripts")
		}
		return try body()
	}
}

// Starts a test server, and when its socket path is already served (Q7: the floor test once
// found a fresh path taken, 1 in 25 full runs) throws HeldSocket, which says who holds it.
@MainActor
func startServing(_ server: MachmanServer) throws {
	do {
		try server.start()
	} catch UDSError.alreadyRunning(let path) {
		throw HeldSocket(path: path)
	}
}

// What a refused test server found at its path: the holder (UDSListener.holderPID), whether
// that is this test process, the file's inode and birth time, and every scratch entry that
// shares the path's prefix (a name collision shows up there).
struct HeldSocket: Error, CustomStringConvertible {
	let path: String
	let holder: pid_t?
	let inode: UInt64?
	let born: Date?
	let siblings: [String]

	init(path: String) {
		self.path = path
		holder = UDSListener.holderPID(path: path)
		var info = stat()
		if stat(path, &info) == 0 {
			inode = UInt64(info.st_ino)
			let birth = info.st_birthtimespec
			born = Date(timeIntervalSince1970:
				TimeInterval(birth.tv_sec) + TimeInterval(birth.tv_nsec) / 1e9)
		} else {
			inode = nil
			born = nil
		}
		let directory = (path as NSString).deletingLastPathComponent
		let name = (path as NSString).lastPathComponent
		let prefix = name.split(separator: "-").prefix(2).joined(separator: "-")
		siblings = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
			.filter { $0.hasPrefix(prefix) }
			.sorted()
	}

	var description: String {
		let holderText = holder.map {
			"holder pid \($0) (this test process: \($0 == getpid() ? "yes" : "no"))"
		} ?? "no holder answered"
		let inodeText = inode.map { "inode \($0)" } ?? "no file"
		let bornText = born.map { "born \(ISO8601DateFormatter().string(from: $0))" } ?? "born ?"
		return "\(path) is already served: \(holderText), \(inodeText), \(bornText); "
			+ "scratch entries with this prefix: \(siblings.joined(separator: ", "))"
	}
}
