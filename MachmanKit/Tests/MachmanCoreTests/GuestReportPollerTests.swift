//
//  GuestReportPollerTests.swift
//  MachmanCoreTests
//
//  S40: the vmhost's report poll reads the guest-writable drop-box off the main actor, one
//  read at a time, and its last look at teardown is synchronous and wins over a read still
//  in flight. Driven on a stub reader — no timer, no files, no sleeps.
//

import Testing
import Foundation
@testable import MachmanCore

// What the stub reader saw, from whichever thread it ran on.
private final class Reads: @unchecked Sendable {
	private let lock = NSLock()
	private var log: [(path: String, since: Date?, onMain: Bool)] = []

	func record(_ path: String, _ since: Date?) {
		let onMain = Thread.isMainThread
		lock.withLock { log.append((path, since, onMain)) }
	}

	var all: [(path: String, since: Date?, onMain: Bool)] { lock.withLock { log } }
}

@MainActor
struct GuestReportPollerTests {

	private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

	// A reader that knows one version of the file (stamp): nothing new once `since` is it.
	private static func reader(_ reads: Reads, user: String) -> GuestReportPoller.Reader {
		{ path, since in
			reads.record(path, since)
			guard since != stamp else { return nil }
			return GuestReport.Found(mtime: stamp, report: GuestReport.parse("USER=\(user)"))
		}
	}

	@Test func pollsReadOffTheMainActorOneAtATime() async throws {
		let reads = Reads()
		var ingested: [String] = []
		let poller = GuestReportPoller(
			path: { "/drop/report.env" }, read: Self.reader(reads, user: "admin")
		) { ingested.append($0.values["USER"] ?? "") }

		let first = try #require(poller.poll())
		#expect(poller.poll() == nil)   // one read in flight: the tick is skipped
		await first.value
		#expect(ingested == ["admin"])
		#expect(reads.all.count == 1)
		#expect(reads.all.first?.onMain == false)
		#expect(reads.all.first?.path == "/drop/report.env")
	}

	// The same version is ingested once; the next look asks for news since its mtime, at the
	// path as it is NOW (Save as New VM moves a running VM's directory).
	@Test func eachVersionIsIngestedOnceAtTheCurrentPath() async throws {
		let reads = Reads()
		var ingested: [String] = []
		var path = "/old/report.env"
		let poller = GuestReportPoller(
			path: { path }, read: Self.reader(reads, user: "admin")
		) { ingested.append($0.values["USER"] ?? "") }

		await poller.poll()?.value
		path = "/saved/report.env"
		await poller.poll()?.value
		poller.stop()
		#expect(ingested == ["admin"])
		#expect(reads.all.map(\.path) == ["/old/report.env", "/saved/report.env",
			"/saved/report.env"])
		#expect(reads.all.map(\.since) == [nil, Self.stamp, Self.stamp])
	}

	// Teardown's last look runs on the caller (the payload goes right after it) and wins: a
	// read still in flight then is dropped, and nothing polls afterwards.
	@Test func stopReadsNowAndDropsAReadInFlight() async throws {
		let reads = Reads()
		var ingested: [String] = []
		let poller = GuestReportPoller(path: { "/drop/report.env" }, read: { path, since in
			reads.record(path, since)
			let user = Thread.isMainThread ? "final" : "in-flight"
			return GuestReport.Found(mtime: Self.stamp, report: GuestReport.parse("USER=\(user)"))
		}) { ingested.append($0.values["USER"] ?? "") }

		let inFlight = try #require(poller.poll())
		poller.stop()
		#expect(ingested == ["final"])
		await inFlight.value
		#expect(ingested == ["final"])
		#expect(poller.poll() == nil)
		poller.stop()
		#expect(reads.all.filter(\.onMain).count == 1)
	}
}
