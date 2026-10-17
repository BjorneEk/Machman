//
//  PersistedSettingsStore.swift
//  MachmanUI
//
//  What every desktop settings store does with its file the same way (Q32): flush() on quit
//  and in tests, and the one-time notice for a file load() had to set aside (P19). The canvas
//  layouts, the terminal profiles and the activity list conform; each names its file and
//  what the notice calls its contents, and gets the rest here.
//

import Foundation

// What a settings store needs of its file, whatever value the file holds.
@MainActor
public protocol PersistedFile: AnyObject {
	// Block until pending writes have landed on disk.
	func flush()
	// Where load() moved an unreadable file, handed out once; nil after that or when none.
	func takeBackupURL() -> URL?
}

@MainActor
public protocol PersistedSettingsStore: SetAsideReporting {
	// The store's file; nil keeps its settings in memory (tests, renders).
	var settingsFile: (any PersistedFile)? { get }
	// What the notice calls the file's contents: "terminal profiles".
	static var settingsDescription: String { get }
}

extension PersistedSettingsStore {
	// Block until pending writes have landed on disk (app termination and tests).
	public func flush() {
		settingsFile?.flush()
	}

	// Handed out once: the stores are app-scoped, so a reconnect's fresh view model doesn't
	// announce the file again.
	public func takeSetAsideNotice() -> SetAsideSettingsFile? {
		settingsFile?.takeBackupURL().map {
			SetAsideSettingsFile(what: Self.settingsDescription, backup: $0)
		}
	}
}
