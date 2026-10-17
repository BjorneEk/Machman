//
//  LabStartFailureTests.swift
//  MachmanLabTests
//
//  L2 harness — Q28's start-failure record: what TFStartFailure keeps of a start that failed in
//  the engine, on a scratch disk image this test locks itself (no agent, no VM, no VZ).
//

import Darwin
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
import Testing

@Suite("Lab start-failure records", .serialized, .enabled(if: Lab.runs(.harness)))
struct LabStartFailureTests {
	static let vzRefusal = MachmanError(
		code: .internalError,
		message: "Invalid virtual machine configuration. The storage device attachment is invalid.")

	// A scratch dir of its own and a disk image file in it.
	static func image(_ name: String) throws -> (dir: String, path: String) {
		let dir = TestEnvironment.scratch + "q28-" + String(UUID().uuidString.prefix(8))
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let path = dir + "/" + name
		#expect(FileManager.default.createFile(atPath: path, contents: Data(count: 4096)))
		return (dir, path)
	}

	static func vm(_ name: String, state: VMState = .stopped, disks: [DiskInfo]) async -> VMInfo {
		var info = await MainActor.run { StubMachman.makeInfo(name, state: state) }
		info.disks = disks
		return info
	}

	@Test("Q28: a disk image another holder has locked reads as write-locked with its holders")
	func lockedDiskReadsLocked() async throws {
		let (_, path) = try Self.image("held.img")
		#expect(TFStartFailure.lock(of: path) == "unlocked")
		let fd = open(path, O_RDWR)
		try #require(fd >= 0)
		defer { close(fd) }
		try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
		let state = await TFStartFailure.diskState(path)
		#expect(state.lock.hasPrefix("write-locked"), "\(state.lock)")
		#expect(state.holders.contains { $0.pid == getpid() }, "\(state.holders)")
		#expect(state.size == 4096)
		flock(fd, LOCK_UN)
		#expect(TFStartFailure.lock(of: path) == "unlocked")
		#expect(TFStartFailure.lock(of: path + ".gone").hasPrefix("can't open it"))
	}

	@Test("Q28: only an engine failure is kept, with its error and every writable disk")
	func onlyEngineFailuresAreRecorded() async throws {
		#expect(!TFStartFailure.isEngineFailure(MachmanError(code: .macConflict, message: "m")))
		#expect(!TFStartFailure.isEngineFailure(MachmanError(code: .invalidState, message: "s")))
		#expect(!TFStartFailure.isEngineFailure(MachmanError(code: .cancelled, message: "c")))
		#expect(!TFStartFailure.isEngineFailure(CancellationError()))
		#expect(TFStartFailure.isEngineFailure(Self.vzRefusal))
		#expect(TFStartFailure.isEngineFailure(
			MachmanError(code: .virtualizationFailure, message: "v")))
		let (dir, boot) = try Self.image("boot.img")
		let iso = dir + "/installer.iso"
		let off = dir + "/disabled.img"
		let named = dir + "/Storage.img"
		let info = await Self.vm("q28 vm", disks: [
			DiskInfo(id: "1", type: .image, name: nil, path: boot, sizeBytes: 4096),
			DiskInfo(id: "2", type: .iso, name: nil, path: iso, sizeBytes: nil),
			DiskInfo(
				id: "3", type: .image, name: nil, path: off, sizeBytes: nil, enabled: false),
			DiskInfo(id: "4", type: .storage, name: "Storage", path: named, sizeBytes: nil),
		])
		var notes: [String] = []
		let refused = await TFStartFailure.keep(
			vm: "q28 vm", error: MachmanError(code: .invalidState, message: "busy"), info: info,
			others: [], reportDir: dir, settle: .zero, vzLog: { [] }, note: { notes.append($0) })
		#expect(refused == nil && notes.isEmpty)
		let kept = try #require(await TFStartFailure.keep(
			vm: "q28 vm", error: Self.vzRefusal, info: info, others: [], reportDir: dir,
			settle: .zero, vzLog: { [] }, note: { notes.append($0) }))
		let text = try String(contentsOfFile: kept, encoding: .utf8)
		#expect(text.contains("internalError: " + Self.vzRefusal.message), "\(text)")
		#expect(text.contains(boot) && text.contains(named), "\(text)")
		#expect(!text.contains(iso) && !text.contains(off), "\(text)")
	}

	@Test("Q28: a record names the VMs sharing its disk, and its warning names its file")
	func recordLandsInTheReport() async throws {
		let (dir, shared) = try Self.image("shared.img")
		let disk = DiskInfo(id: "1", type: .image, name: nil, path: shared, sizeBytes: 4096)
		let copy = await Self.vm("q28 copy", disks: [disk])
		let source = await Self.vm("q28 source", disks: [disk])
		let elsewhere = await Self.vm("q28 elsewhere", state: .running, disks: [
			DiskInfo(id: "2", type: .image, name: nil, path: dir + "/own.img", sizeBytes: 1),
		])
		let fd = open(shared, O_RDWR)
		try #require(fd >= 0)
		defer { close(fd) }
		try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
		var notes: [String] = []
		let kept = try #require(await TFStartFailure.keep(
			vm: "q28 copy", error: Self.vzRefusal, info: copy, others: [source, elsewhere],
			reportDir: dir + "/report", settle: .milliseconds(10),
			vzLog: { ["12:00:00.000 E  com.apple.Virtualization.VirtualMachine: q28 marker"] },
			note: { notes.append($0) }))
		#expect(kept.hasPrefix(dir + "/report/start-failures/") && kept.hasSuffix(".txt"))
		let text = try String(contentsOfFile: kept, encoding: .utf8)
		#expect(text.contains("q28 source: stopped"), "\(text)")
		#expect(!text.contains("q28 elsewhere"), "\(text)")
		#expect(text.contains("write-locked"), "\(text)")
		#expect(text.contains("q28 marker"), "\(text)")
		#expect(notes.count == 1)
		#expect(notes.first?.contains(kept) == true, "\(notes)")
		#expect(notes.first?.contains("The storage device attachment is invalid.") == true)
		#expect(notes.first?.contains("write-locked") == true, "\(notes)")
	}

	@Test("Q28: a lost connection or any other error but the engine's is never kept")
	func onlyEngineErrorsCount() {
		#expect(!TFStartFailure.isEngineFailure(RPCConnection.ConnectionError.disconnected))
		#expect(!TFStartFailure.isEngineFailure(
			RPCConnection.ConnectionError.connectFailed("/x.sock", ECONNREFUSED)))
		#expect(!TFStartFailure.isEngineFailure(LabError.specInvalid("no")))
		#expect(!TFStartFailure.isEngineFailure(NSError(domain: NSPOSIXErrorDomain, code: 5)))
		#expect(TFStartFailure.isEngineFailure(NSError(domain: "VZErrorDomain", code: 2)))
		#expect(TFStartFailure.isEngineFailure(MachmanError(code: .ioFailure, message: "i")))
	}

	@Test("Q28: a record's name carries its test process, so a later one of a VM so named stays")
	func recordNamesCarryTheProcess() async throws {
		let (dir, path) = try Self.image("x.img")
		let info = await Self.vm("x", disks: [
			DiskInfo(id: "1", type: .image, name: nil, path: path, sizeBytes: 4096),
		])
		var kept: [String] = []
		for _ in 0..<2 {
			kept.append(try #require(await TFStartFailure.keep(
				vm: "x", error: Self.vzRefusal, info: info, others: [], reportDir: dir,
				settle: .zero, vzLog: { [] }, note: { _ in })))
		}
		#expect(Set(kept).count == 2)
		#expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0) })
		#expect(kept.allSatisfy {
			($0 as NSString).lastPathComponent.hasPrefix("\(getpid())-")
		}, "\(kept)")
	}
}
