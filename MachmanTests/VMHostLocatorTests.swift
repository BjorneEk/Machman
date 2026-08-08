//
//  VMHostLocatorTests.swift
//  MachmanTests
//
//  Pure path math over fixture trees — the locator takes an injected bundle URL.
//

import Foundation
import Testing
@testable import MachmanCore

struct VMHostLocatorTests {
	private func makeTree() throws -> URL {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("locator-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private func plantVMHost(at dir: URL) throws {
		let exec = dir.appendingPathComponent("MachmanVMHost.app/Contents/MacOS")
		try FileManager.default.createDirectory(at: exec, withIntermediateDirectories: true)
		FileManager.default.createFile(
			atPath: exec.appendingPathComponent("MachmanVMHost").path, contents: Data())
	}

	@Test func embeddedLayoutResolves() throws {
		let root = try makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		let library = root.appendingPathComponent("Outer.app/Contents/Library")
		let daemon = library.appendingPathComponent("LoginItems/Machmand.app")
		try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
		try plantVMHost(at: library)

		let location = try #require(VMHostLocator.locate(from: daemon))
		#expect(location.appURL.path == library.appendingPathComponent("MachmanVMHost.app").path)
	}

	@Test func siblingBuildProductResolves() throws {
		let root = try makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		let daemon = root.appendingPathComponent("Machmand.app")
		try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
		try plantVMHost(at: root)

		let location = try #require(VMHostLocator.locate(from: daemon))
		#expect(location.appURL.path == root.appendingPathComponent("MachmanVMHost.app").path)
	}

	@Test func embeddedWinsOverSibling() throws {
		let root = try makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		let library = root.appendingPathComponent("Outer.app/Contents/Library")
		let loginItems = library.appendingPathComponent("LoginItems")
		let daemon = loginItems.appendingPathComponent("Machmand.app")
		try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
		try plantVMHost(at: library)
		try plantVMHost(at: loginItems)   // a sibling of the daemon, should lose

		let location = try #require(VMHostLocator.locate(from: daemon))
		#expect(location.appURL.path == library.appendingPathComponent("MachmanVMHost.app").path)
	}

	@Test func nothingFoundIsNil() throws {
		let root = try makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		let daemon = root.appendingPathComponent("Machmand.app")
		try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)

		#expect(VMHostLocator.locate(from: daemon) == nil)
	}
}
