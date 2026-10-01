//
//  PersistedJSONFile.swift
//  MachmanUI
//
//  One desktop settings file (terminal profiles, canvas layouts): read once at launch and
//  written atomically off the main thread. Writes coalesce: the first change after a write
//  opens a short window and later changes only replace the snapshot, so a divider drag
//  writes about twice a second, not once per frame; flush() writes what is pending (quit,
//  tests). A file that can't be read at all is never overwritten: it is moved aside to
//  <name>.bak (.bak.2, … — an earlier backup is never replaced) and the store starts fresh;
//  if even that move fails, nothing is written this session. Values inside a readable file
//  decode tolerantly (TolerantDecoding.swift).
//

import Foundation
import MachmanAPI

@MainActor
public final class PersistedJSONFile<Value: Codable & Sendable> {
	public let url: URL
	// Where load() moved an unreadable file; nil when it read fine or was absent.
	public private(set) var backupURL: URL?
	private let label: String
	// Serial, so a rapid edit stream never blocks the UI on disk I/O; flush() waits for it.
	private let queue: DispatchQueue
	private let saveDelay: Duration
	private var writable = true
	// The newest unsaved value, and the timer that writes it.
	private var pending: Value?
	private var timer: Task<Void, Never>?

	public init(
		url: URL, label: String, queueLabel: String, saveDelay: Duration = .milliseconds(500)
	) {
		self.url = url
		self.label = label
		self.queue = DispatchQueue(label: queueLabel, qos: .utility)
		self.saveDelay = saveDelay
	}

	// The stored value; nil when there is no file yet or it could not be read.
	public func load() -> Value? {
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		do {
			return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
		} catch {
			setAside(after: error)
			return nil
		}
	}

	public func save(_ value: Value) {
		guard writable else { return }
		pending = value
		guard timer == nil else { return }
		let delay = saveDelay
		// Holds the file strongly on purpose: a pending write outlives its store.
		timer = Task { @MainActor in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled else { return }
			self.writePending()
		}
	}

	// Block until pending writes have landed on disk (app termination and tests).
	public func flush() {
		timer?.cancel()
		writePending()
		queue.sync {}
	}

	private func writePending() {
		timer = nil
		guard let value = pending else { return }
		pending = nil
		let url = url
		let label = label
		queue.async {
			do {
				let encoder = JSONEncoder()
				encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
				let data = try encoder.encode(value)
				try FileManager.default.createDirectory(
					at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				try data.write(to: url, options: .atomic)
			} catch {
				MachmanLogger.log(.passiveError, "\(label) save failed: \(error)")
			}
		}
	}

	private func setAside(after error: Error) {
		let file = url.lastPathComponent
		let fm = FileManager.default
		var moveError: Error?
		for n in 1...99 {
			let candidate = url.deletingLastPathComponent()
				.appendingPathComponent(file + (n == 1 ? ".bak" : ".bak.\(n)"))
			if fm.fileExists(atPath: candidate.path) { continue }
			do {
				try fm.moveItem(at: url, to: candidate)
				backupURL = candidate
				MachmanLogger.log(
					.passiveError,
					"\(label): \(file) could not be read (\(error)); kept as "
						+ "\(candidate.lastPathComponent), starting fresh")
				return
			} catch {
				moveError = error
				break
			}
		}
		writable = false
		MachmanLogger.log(
			.passiveError,
			"\(label): \(file) could not be read (\(error)) or set aside "
				+ "(\(moveError.map { "\($0)" } ?? "no free .bak name")); left untouched, "
				+ "not saving \(label) this session")
	}
}

// A settings file this launch could not read and set aside, for the one-time notice.
public struct SetAsideSettingsFile: Equatable, Sendable {
	public let what: String     // "terminal profiles"
	public let backup: URL

	public init(what: String, backup: URL) {
		self.what = what
		self.backup = backup
	}
}

// A store whose file may have been set aside at launch. The notice is handed out once: the
// stores are app-scoped, so a reconnect's fresh view model doesn't announce it again.
@MainActor
public protocol SetAsideReporting: AnyObject {
	func takeSetAsideNotice() -> SetAsideSettingsFile?
}
