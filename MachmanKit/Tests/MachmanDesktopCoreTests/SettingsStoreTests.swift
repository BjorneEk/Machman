//
//  SettingsStoreTests.swift
//  MachmanDesktopCoreTests
//
//  Q32: the canvas layouts, the terminal profiles and the activity list each kept the same
//  set-aside notice and flush plumbing. They share PersistedSettingsStore now: an unreadable
//  file is announced once, under each store's own words, through the shared extension.
//

import Testing
import Foundation
import MachmanUI
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: the stores on files in the run's scratch space.
@MainActor
struct SettingsStoreTests {
	// A fresh folder holding one unreadable settings file.
	private func unreadable(_ name: String) throws -> URL {
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let url = dir.appendingPathComponent(name)
		try Data("not json".utf8).write(to: url)
		return url
	}

	@Test("Q32: a settings store hands out its set-aside notice once")
	func eachStoreAnnouncesASetAsideFileOnce() throws {
		let stores: [(any PersistedSettingsStore, String, URL)] = try [
			{
				let url = try unreadable("Canvas.json")
				return (CanvasStateStore(fileURL: url), "tab layouts", url)
			}(),
			{
				let url = try unreadable("Profiles.json")
				return (TerminalProfileStore(fileURL: url), "terminal profiles", url)
			}(),
			{
				let url = try unreadable("Activity.json")
				return (ActivityLog(fileURL: url), "activity list", url)
			}(),
		]
		for (store, what, url) in stores {
			let notice = store.takeSetAsideNotice()
			#expect(notice?.what == what)
			#expect(notice?.backup.lastPathComponent == url.lastPathComponent + ".bak")
			#expect(store.takeSetAsideNotice() == nil, "\(what): announced twice")
			store.flush()
		}
		// In memory, nothing was set aside.
		#expect(ActivityLog().takeSetAsideNotice() == nil)
	}
}
