import Testing
import Foundation
@testable import MachmanCore

// A force quit, a crash, or a power loss all skip every cleanup path the code has. What survives
// on disk afterwards must not brick the app: stale sockets get reclaimed, and a config being
// written at the moment the power went is either the old one or the new one, never a fragment.
struct CrashRecoveryTests {

	// MARK: - Sockets

	@Test func aSocketFileWithNothingBehindItIsNotLive() throws {
		let path = NSTemporaryDirectory() + "mm-dead-\(UUID().uuidString).sock"
		FileManager.default.createFile(atPath: path, contents: Data())
		defer { try? FileManager.default.removeItem(atPath: path) }
		// Exactly what a killed daemon leaves: the file, with no listener.
		#expect(UDSListener.isLive(path: path) == false)
	}

	@Test func aLiveListenerIsDetected() throws {
		let path = NSTemporaryDirectory() + "mm-live-\(UUID().uuidString).sock"
		let listener = try UDSListener(path: path, queue: .global()) { fd in close(fd) }
		defer { listener.shutdown() }
		#expect(UDSListener.isLive(path: path) == true)
	}

	// The important half: a leftover file must not permanently block the socket.
	@Test func aStaleSocketIsReclaimedRatherThanRefused() throws {
		let path = NSTemporaryDirectory() + "mm-stale-\(UUID().uuidString).sock"
		let first = try UDSListener(path: path, queue: .global()) { fd in close(fd) }
		// Simulate SIGKILL: drop the listener without shutdown(), leaving the file behind.
		first.simulateKillForTesting()
		#expect(FileManager.default.fileExists(atPath: path))

		let second = try UDSListener(path: path, queue: .global()) { fd in close(fd) }
		defer { second.shutdown() }
		#expect(UDSListener.isLive(path: path) == true)
	}

	@Test func aSecondLiveListenerIsRefused() throws {
		let path = NSTemporaryDirectory() + "mm-dup-\(UUID().uuidString).sock"
		let first = try UDSListener(path: path, queue: .global()) { fd in close(fd) }
		defer { first.shutdown() }
		#expect(throws: UDSError.self) {
			_ = try UDSListener(path: path, queue: .global()) { fd in close(fd) }
		}
	}

	// MARK: - Config durability

	@Test func configSurvivesATruncatedWriteAttempt() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "durable")
			let cfg = try VMConfig(name: "durable", memorySize: 2048, cpuCount: 2)
			try cfg.setCPUCount(4)

			// A non-atomic writer would leave this fragment as the config itself. Atomic writes
			// stage in a sibling file, so a crash mid-save can only ever lose the NEW value.
			let path = cfg.configPath()
			let good = try Data(contentsOf: URL(fileURLWithPath: path))
			#expect((try? JSONDecoder().decode(VMConfig.self, from: good)) != nil)
			#expect(try VMConfig.load(name: "durable").cpuCount == 4)

			// And the parse failure a fragment WOULD cause is surfaced, not swallowed.
			try Data(good.prefix(good.count / 2)).write(to: URL(fileURLWithPath: path))
			#expect(throws: (any Error).self) { _ = try VMConfig.load(name: "durable") }
		}
	}

	// A VM whose config cannot be read must not take the whole scan down with it.
	@MainActor
	@Test func oneUnreadableVMDoesNotHideTheOthers() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "healthy")
			_ = try VMConfig(name: "healthy", memorySize: 2048, cpuCount: 2)
			try VMConfig.createNewVMDirectory(name: "damaged")
			try Data("{ truncated".utf8).write(
				to: URL(fileURLWithPath: machmanVMDir + "/damaged/config"))

			let registry = VMRegistry()
			#expect(registry.vm(named: "healthy") != nil)
			#expect(registry.vm(named: "damaged") == nil)
		}
	}
}
