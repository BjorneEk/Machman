//
//  ActivityLogTests.swift
//  MachmanDesktopCoreTests
//
//  PR5 / F1 / F6: a failure after the RPC returned showed only on its card for five
//  seconds, and an engine warning only in a four-second toast; nothing kept them. The
//  activity list keeps finished operations, engine warnings and the desktop's problem
//  toasts: the 50 newest, newest first, problems unseen until it is opened, across
//  reconnects, and (A-3d-1) on disk across relaunches.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct ActivityLogTests {
	private func entry(_ n: Int, severity: ActivityEntry.Severity = .warning) -> ActivityEntry {
		ActivityEntry(
			date: Date(timeIntervalSince1970: 1_780_000_000 + Double(n)), vm: "Debian",
			title: "Debian", detail: "warning \(n)", symbol: MachmanSymbols.warning,
			severity: severity)
	}

	private func scratchFile() -> URL {
		TestEnvironment.scratchURL.appendingPathComponent("activity-\(UUID().uuidString)")
			.appendingPathComponent("Activity.json")
	}

	// MARK: - What lands in the list

	@Test func aFinishedOperationIsListed() async {
		let h = await DesktopHarness.make()
		h.stub.emit(.operationChanged(op: Samples.failedImport()))
		#expect(await eventually { h.viewModel.activity.entries.count == 1 })
		let listed = h.viewModel.activity.entries.first
		#expect(listed?.title == "Debian — Importing big-archive-disk-image-2026.raw")
		#expect(listed?.detail == Samples.failedImport().message)
		#expect(listed?.severity == .failure)
		#expect(h.viewModel.activity.unseenProblems == 1)
	}

	// Its progress events never list it; its end is listed once, though a resync (a
	// reconnect while the daemon still lists it) brings it again.
	@Test func anOperationIsListedOnceWhenItEnds() async {
		let h = await DesktopHarness.make()
		var op = Samples.copyFromOperation()
		h.stub.emit(.operationChanged(op: op))
		#expect(await eventually { h.operations.operations.map(\.id) == [op.id] })
		#expect(h.viewModel.activity.entries.isEmpty)
		op.state = OperationInfo.State.cancelled
		h.stub.emit(.operationChanged(op: op))
		#expect(await eventually { h.viewModel.activity.entries.count == 1 })
		h.stub.ops = [op]
		let resyncs = h.stub.calls.filter { $0 == "operations" }.count
		h.operations.attach(api: h.stub)
		#expect(await eventually {
			h.stub.calls.filter { $0 == "operations" }.count > resyncs
		})
		#expect(await h.settled())
		#expect(h.viewModel.activity.entries.count == 1)
		#expect(h.viewModel.activity.entries.first?.detail == "Canceled")
	}

	@Test func aSuccessIsListedButNotBadged() async {
		let h = await DesktopHarness.make()
		h.stub.emit(.operationChanged(op: Samples.finishedImport()))
		#expect(await eventually { h.viewModel.activity.entries.count == 1 })
		#expect(h.viewModel.activity.entries.first?.severity == .done)
		#expect(h.viewModel.activity.unseenProblems == 0)
	}

	@Test func anEngineWarningIsListedWithItsVM() async {
		let h = await DesktopHarness.make()
		for _ in 0..<2 {
			h.stub.emit(.log(vm: "Debian", level: .warning, message: "uart dropped"))
		}
		h.stub.emit(.log(vm: nil, level: .error, message: "sentinel"))
		#expect(await eventually { h.viewModel.activity.entries.count == 2 })
		let warning = h.viewModel.activity.entries.first { $0.detail == "uart dropped" }
		#expect(warning?.title == "Debian")
		#expect(warning?.severity == .warning)
		#expect(h.viewModel.activity.entries.first?.title == "Machman")
		#expect(h.viewModel.activity.entries.first?.severity == .failure)
		#expect(h.viewModel.activity.unseenProblems == 2)
	}

	@Test func aGuestThatErrorsIsListed() async {
		let h = await DesktopHarness.make()
		var fedora = h.stub.vms["Fedora"]!
		fedora.state = .running
		h.stub.vms["Fedora"] = fedora
		h.stub.emit(.listChanged)
		#expect(await eventually { h.store.vms.first { $0.name == "Fedora" }?.state == .running })
		fedora.state = .error
		h.stub.vms["Fedora"] = fedora
		h.stub.emit(.listChanged)
		#expect(await eventually { !h.viewModel.activity.entries.isEmpty })
		#expect(h.viewModel.activity.entries.first?.title == "Fedora")
		#expect(h.viewModel.activity.entries.first?.severity == .failure)
		// The toast itself is unchanged.
		#expect(h.viewModel.toasts.contains { $0.message == "Fedora hit an error" })
	}

	// MARK: - The list itself

	@Test func theListKeepsTheNewestFifty() {
		let log = ActivityLog()
		for n in 1...60 { log.record(entry(n)) }
		#expect(log.entries.count == ActivityLog.capacity)
		#expect(log.entries.first?.detail == "warning 60")
		#expect(log.entries.last?.detail == "warning 11")
		#expect(log.unseen == Set(log.entries.map(\.id)))
	}

	@Test func entriesClearOneByOneOrAllAtOnce() {
		let log = ActivityLog()
		for n in 1...3 { log.record(entry(n)) }
		let second = log.entries[1].id
		log.dismiss(id: second)
		#expect(log.entries.map(\.detail) == ["warning 3", "warning 1"])
		#expect(!log.unseen.contains(second))
		log.clearAll()
		#expect(log.entries.isEmpty)
		#expect(log.unseenProblems == 0)
	}

	@Test func openingTheListKeepsItsEntries() {
		let log = ActivityLog()
		for n in 1...2 { log.record(entry(n)) }
		log.markSeen()
		#expect(log.unseenProblems == 0)
		#expect(log.entries.count == 2)
	}

	// The view model is per connection; the list is the store's (DaemonConnection.attach's
	// shape: detach, re-attach, a fresh view model over the same stores).
	@Test func theListSurvivesAReconnect() async {
		let h = await DesktopHarness.make()
		h.stub.emit(.log(vm: "Debian", level: .warning, message: "uart dropped"))
		#expect(await eventually { h.viewModel.activity.entries.count == 1 })
		h.operations.detach()
		h.operations.attach(api: h.stub)
		let next = VMListViewModel(
			api: h.stub, store: h.store, operations: h.operations, terminals: h.terminals,
			previews: h.previews, canvases: h.canvases, tornTabs: h.tornTabs)
		#expect(next.activity === h.viewModel.activity)
		#expect(next.activity.entries.count == 1)
		#expect(next.activity.unseenProblems == 1)
	}

	// MARK: - On disk (A-3d-1)

	@Test func theListRoundTripsThroughTheFile() {
		let url = scratchFile()
		let log = ActivityLog(fileURL: url)
		log.record(entry(1, severity: .done))
		log.record(entry(2))
		log.flush()
		let reloaded = ActivityLog(fileURL: url)
		#expect(reloaded.entries == log.entries)
		#expect(reloaded.unseen == log.unseen)
		#expect(reloaded.unseenProblems == 1)
	}

	@Test func removalsReachTheFile() {
		let url = scratchFile()
		let log = ActivityLog(fileURL: url)
		for n in 1...3 { log.record(entry(n)) }
		log.dismiss(id: log.entries[0].id)
		log.markSeen()
		log.flush()
		let reloaded = ActivityLog(fileURL: url)
		#expect(reloaded.entries.map(\.detail) == ["warning 2", "warning 1"])
		#expect(reloaded.unseenProblems == 0)
		reloaded.clearAll()
		reloaded.flush()
		#expect(ActivityLog(fileURL: url).entries.isEmpty)
	}

	// A file another build wrote with more than 50 entries loads the 50 newest.
	@Test func aLongerFileLoadsTheNewestFifty() throws {
		let url = scratchFile()
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let entries = (1...70).map { entry($0) }
		let state = ActivityLog.PersistedState(entries: entries, unseen: entries.map(\.id))
		try JSONEncoder().encode(state).write(to: url)
		let log = ActivityLog(fileURL: url)
		#expect(log.entries.count == ActivityLog.capacity)
		#expect(log.entries.first?.detail == "warning 70")
		#expect(log.entries.last?.detail == "warning 21")
		#expect(log.unseen == Set(log.entries.map(\.id)))
	}

	// One bad entry costs only that entry; a severity this build doesn't know reads as info.
	@Test func aBadEntryCostsOnlyItself() throws {
		let url = scratchFile()
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let good = UUID()
		let json = #"{"entries":[{"id":"\#(good.uuidString)","date":1,"title":"Debian","#
			+ #""symbol":"x","severity":"catastrophe"},{"title":"no id"}],"unseen":[]}"#
		try Data(json.utf8).write(to: url)
		let log = ActivityLog(fileURL: url)
		#expect(log.entries.map(\.id) == [good])
		#expect(log.entries.first?.severity == .info)
	}

	// An unreadable file is never overwritten: it is kept as .bak and announced once.
	@Test func anUnreadableFileIsKeptAsBak() throws {
		let url = scratchFile()
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("not json".utf8).write(to: url)
		let log = ActivityLog(fileURL: url)
		#expect(log.entries.isEmpty)
		let backup = url.deletingLastPathComponent().appendingPathComponent("Activity.json.bak")
		#expect(try String(contentsOf: backup, encoding: .utf8) == "not json")
		#expect(log.takeSetAsideNotice()?.what == "activity list")
		#expect(log.takeSetAsideNotice() == nil)
	}

	// Writes coalesce; flush() lands the pending one (the app calls it on quit).
	@Test func flushWritesWhatIsPending() {
		let url = scratchFile()
		let log = ActivityLog(fileURL: url, saveDelay: .seconds(60))
		log.record(entry(1))
		#expect(!FileManager.default.fileExists(atPath: url.path))
		log.flush()
		#expect(ActivityLog(fileURL: url).entries.count == 1)
	}
}
