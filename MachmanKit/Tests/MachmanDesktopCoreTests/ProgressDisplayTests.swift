//
//  ProgressDisplayTests.swift
//  MachmanDesktopCoreTests
//
//  Q4: the canvas install banner and the corner card each kept a copy of the phase label,
//  and the card two copies of the ETA rule. One of each now: InstallPhase.displayLabel and
//  ProgressETA (the rate so far over what is left, nil until there is a rate).
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
@testable import MachmanDesktopCore

struct ProgressDisplayTests {
	private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

	@Test func installPhasesReadAsTheBannerSaysThem() {
		#expect(InstallPhase(kind: .resolving).displayLabel == "Resolving…")
		#expect(InstallPhase(kind: .downloading, version: "15.4").displayLabel
			== "Downloading macOS 15.4…")
		#expect(InstallPhase(kind: .installing, version: "15.4").displayLabel
			== "Installing macOS 15.4…")
	}

	@Test func etaIsTheRateSoFarOverWhatIsLeft() {
		let eta = ProgressETA.seconds(
			done: 25, total: 100, since: t0, now: t0.addingTimeInterval(10))
		#expect(eta == 30)
	}

	@Test func noETAUntilThereIsARate() {
		let later = t0.addingTimeInterval(10)
		#expect(ProgressETA.seconds(done: 0, total: 100, since: t0, now: later) == nil)
		#expect(ProgressETA.seconds(
			done: 25, total: 100, since: t0, now: t0.addingTimeInterval(1)) == nil)
		#expect(ProgressETA.seconds(done: 100, total: 100, since: t0, now: later) == nil)
		#expect(ProgressETA.seconds(done: 25, total: 100, since: nil, now: later) == nil)
		#expect(ProgressETA.seconds(done: nil, total: 100, since: t0, now: later) == nil)
	}

	@Test func onlyRunningOperationsAndDownloadsHaveAnETA() {
		let copy = Samples.copyOperation()
		#expect(copy.etaSeconds(now: copy.startedAt.addingTimeInterval(90)) != nil)
		let done = Samples.finishedImport()
		#expect(done.etaSeconds(now: done.startedAt.addingTimeInterval(90)) == nil)
		// 4 of 16 GB two minutes in: 12 GB left at 2 GB a minute.
		let download = Samples.downloadingMacInstall()
		let eta = download.etaSeconds(now: Samples.now)
		#expect(eta.map { abs($0 - 360) < 0.001 } == true)
		var installing = download
		installing.kind = .installing
		#expect(installing.etaSeconds(now: Samples.now) == nil)
	}
}
