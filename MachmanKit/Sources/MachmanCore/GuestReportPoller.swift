//
//  GuestReportPoller.swift
//  MachmanCore
//
//  Ingests the guest's setup report while its VM runs: a 2 s mtime poll of the drop-box,
//  each read off the main actor (the file is guest-writable, so even its bounded read stays
//  off the thread the VM is driven from) and never two at once. stop() takes one last look,
//  synchronously — the payload is removed right after it, and the vmhost may exit — and
//  drops a read still in flight. The path is asked for at every look: Save as New VM renames
//  a running VM's directory.
//

import Foundation

@MainActor
final class GuestReportPoller {
	typealias Reader = @Sendable (_ path: String, _ since: Date?) -> GuestReport.Found?

	private let path: () -> String
	private let read: Reader
	private let ingest: (GuestReport) -> Void
	private var timer: Timer?
	private var mtime: Date?
	private var reading = false
	private var stopped = false

	init(
		path: @escaping () -> String,
		read: @escaping Reader = { GuestReport.poll(atPath: $0, since: $1) },
		ingest: @escaping (GuestReport) -> Void
	) {
		self.path = path
		self.read = read
		self.ingest = ingest
	}

	// A report is a rare, tiny file: a 2 s mtime stat is effectively free (InstallSession's
	// timer pattern; the body hops back to the main actor).
	func start(every interval: TimeInterval = 2) {
		guard timer == nil, !stopped else { return }
		timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
			[weak self] _ in
			Task { @MainActor [weak self] in
				self?.poll()
			}
		}
	}

	// One look at the drop-box, off the main actor; nil (no read started) while one is still
	// in flight or after stop(). The returned task ends once its result is ingested or dropped.
	@discardableResult
	func poll() -> Task<Void, Never>? {
		guard !reading, !stopped else { return nil }
		reading = true
		let path = path(), since = mtime, read = read
		return Task { @MainActor [weak self] in
			let found = await Task.detached(priority: .utility) { read(path, since) }.value
			guard let self else { return }
			self.reading = false
			guard !self.stopped else { return }
			self.take(found)
		}
	}

	// The last look, on the caller's thread: a report written seconds before shutdown must
	// not be lost. A read still in flight is dropped — this one is newer.
	func stop() {
		guard !stopped else { return }
		stopped = true
		timer?.invalidate()
		timer = nil
		take(read(path(), mtime))
	}

	private func take(_ found: GuestReport.Found?) {
		guard let found else { return }
		mtime = found.mtime
		if let report = found.report {
			ingest(report)
		}
	}
}
