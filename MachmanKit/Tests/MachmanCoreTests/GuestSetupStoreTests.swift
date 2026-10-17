//
//  GuestSetupStoreTests.swift
//  MachmanCoreTests
//
//  The host-side store of Guest Setup scripts (S67): one entry per content, named by it,
//  written whole or not at all, never trusted once its script stops matching the digest it
//  was stored under, and the newest build's script as the latest.
//

import Foundation
import Testing
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

// L1: unit (a store in this test's own scratch directory).
struct GuestSetupStoreTests {
	static func root() -> URL {
		TestEnvironment.scratchURL.appendingPathComponent("scripts-\(UUID().uuidString)")
	}

	static func script(_ version: Int, _ body: String = "echo hello") -> Data {
		Data("#!/bin/sh\nSCRIPT_VERSION=\(version)\n\(body)\n".utf8)
	}

	// The entry directories on disk, staging ones included.
	static func listing(_ root: URL) -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
	}

	@Test("S67: the build's script is stored once as v<N>-<digest>, however often it is added")
	func theBuildsScriptIsStoredOnce() throws {
		let root = Self.root()
		let store = GuestSetupStore(root: root)
		let build = store.builtIn.entry
		// Before anything is stored, the build's own script is listed, undated.
		#expect(store.entries() == [build])
		#expect(build.addedAt == nil)
		#expect(build.id.range(of: #"^v[0-9]+-[0-9a-f]{12}$"#, options: .regularExpression)
			!= nil, "\(build.id)")
		#expect(build.version == GuestSetupInstaller.scriptVersion)
		#expect(build.cksum == POSIXChecksum.cksum(Data(GuestSetupInstaller.script.text.utf8)))

		let stored = try #require(store.ensureBuiltIn())
		#expect(store.ensureBuiltIn() == stored)
		// The build's bytes imported as a custom script are the build's entry.
		#expect(try store.add(store.builtIn.data, kind: GuestSetupStore.Kind.custom) == stored)
		#expect(Self.listing(root) == [build.id])
		#expect(stored.id == build.id && stored.addedAt != nil)
		#expect(store.script(id: build.id) == store.builtIn.data)
	}

	@Test("S67: a script added twice keeps its first entry, date and VM")
	func aScriptAddedTwiceKeepsItsFirstEntry() throws {
		let root = Self.root()
		let store = GuestSetupStore(root: root)
		let data = Self.script(8, "echo patched")
		let first = Date(timeIntervalSince1970: 1_800_000_000)
		let entry = try store.add(
			data, kind: GuestSetupStore.Kind.custom, vm: "Debian", label: "patched.sh", at: first)
		let again = try store.add(
			data, kind: GuestSetupStore.Kind.changed, vm: "Alpine", label: "other.sh",
			at: first.addingTimeInterval(60))
		#expect(again == entry)
		#expect(entry.id.hasPrefix("custom-"))
		#expect(entry.vm == "Debian" && entry.label == "patched.sh" && entry.addedAt == first)
		#expect(entry.version == 8)
		#expect(Self.listing(root) == [entry.id])
		#expect(store.matching(cksum: POSIXChecksum.cksum(data)) == [entry])
		#expect(store.script(id: entry.id) == data)
	}

	@Test("S67: an entry whose script no longer matches its digest is left out")
	func aBrokenEntryIsLeftOut() throws {
		let root = Self.root()
		// Stored by an earlier process, then altered before this one first looked.
		let entry = try GuestSetupStore(root: root).add(
			Self.script(8, "echo kept"), kind: GuestSetupStore.Kind.custom, vm: "Debian")
		let file = root.appendingPathComponent(entry.id)
			.appendingPathComponent(GuestSetupStore.scriptName)
		let other = Self.root()
		try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
		try FileManager.default.copyItem(
			at: root.appendingPathComponent(entry.id), to: other.appendingPathComponent(entry.id))
		try Data("echo swapped\n".utf8).write(
			to: other.appendingPathComponent(entry.id)
				.appendingPathComponent(GuestSetupStore.scriptName))
		let reader = GuestSetupStore(root: other)
		#expect(!reader.entries().contains { $0.id == entry.id })
		#expect(reader.script(id: entry.id) == nil)

		// Altered after it was listed: never served.
		let store = GuestSetupStore(root: root)
		#expect(store.entry(id: entry.id) != nil)
		try Data("echo swapped\n".utf8).write(to: file)
		#expect(store.script(id: entry.id) == nil)
	}

	// F25: every add moved the root's mtime and the next listing — in the daemon and every
	// vmhost — read and hashed every stored script again. A listing reads no script's bytes
	// now; serving and pinning still check the digest.
	@Test("S67: a listing reads no script's bytes, and serving still checks them")
	func aListingReadsNoScript() throws {
		let root = Self.root()
		let store = GuestSetupStore(root: root)
		let kept = try store.add(Self.script(8, "echo kept"), kind: GuestSetupStore.Kind.custom)
		let file = root.appendingPathComponent(kept.id)
			.appendingPathComponent(GuestSetupStore.scriptName)
		try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
		defer {
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o600], ofItemAtPath: file.path)
		}
		// Another add moves the root's mtime: the next listing reads the root again.
		try store.add(Self.script(8, "echo next"), kind: GuestSetupStore.Kind.custom)
		#expect(store.entry(id: kept.id) == kept)
		#expect(store.script(id: kept.id) == nil)
	}

	@Test("S67: the latest is the newest build entry, never a custom one")
	func theLatestIsTheNewestBuild() throws {
		let root = Self.root()
		let older = GuestSetupStore(
			root: root, builtIn: GuestSetupStore.Script(data: Self.script(7)))
		#expect(older.latest == older.builtIn.entry)
		try older.add(Self.script(99, "echo mine"), kind: GuestSetupStore.Kind.custom)
		try older.add(Self.script(6), kind: GuestSetupStore.Kind.build)
		let stored = try #require(older.ensureBuiltIn())
		#expect(older.latest == stored)

		// The next build over the same store: its script is the latest, the older one stays.
		let newer = GuestSetupStore(
			root: root, builtIn: GuestSetupStore.Script(data: Self.script(8)))
		#expect(newer.latest == newer.builtIn.entry)
		#expect(newer.entry(id: stored.id) == stored)
		#expect(newer.entries().count == 4)
	}

	@Test("S67: two stores adding one script at once leave one whole entry")
	func concurrentAddsLeaveOneEntry() throws {
		let root = Self.root()
		let data = Self.script(8, "echo raced")
		let ids = Locked<[String]>([])
		DispatchQueue.concurrentPerform(iterations: 8) { _ in
			let entry = try? GuestSetupStore(root: root).add(
				data, kind: GuestSetupStore.Kind.custom, vm: "Debian")
			ids.mutate { $0.append(entry?.id ?? "failed") }
		}
		let entry = try #require(GuestSetupStore(root: root).matching(
			cksum: POSIXChecksum.cksum(data)).first)
		#expect(ids.value == Array(repeating: entry.id, count: 8))
		#expect(Self.listing(root) == [entry.id], "a staging directory was left behind")
		#expect(GuestSetupStore(root: root).script(id: entry.id) == data)
	}
}

// A value several threads append to.
private final class Locked<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: Value

	init(_ value: Value) { stored = value }

	var value: Value {
		lock.lock()
		defer { lock.unlock() }
		return stored
	}

	func mutate(_ change: (inout Value) -> Void) {
		lock.lock()
		defer { lock.unlock() }
		change(&stored)
	}
}
