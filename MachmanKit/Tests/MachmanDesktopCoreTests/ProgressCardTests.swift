//
//  ProgressCardTests.swift
//  MachmanDesktopCoreTests
//
//  F2 / P24: a progress card's ✕ sent op.cancel whatever the card showed, so closing a Done
//  or Failed card raised "Canceling the operation failed — no operation 'op-…'". A finished
//  card's ✕ now only dismisses it; a running card's still cancels, and a cancel that finds
//  the operation already gone stays quiet (its card shows the outcome).
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct ProgressCardTests {

	@Test func aFinishedCardsCloseOnlyDismisses() async {
		let h = await DesktopHarness.make()
		h.stub.emit(.operationChanged(op: Samples.finishedImport()))
		#expect(await eventually(timeout: .seconds(5)) {
			h.operations.operations.map(\.id) == ["op-import-done"]
		})
		h.viewModel.closeProgressCard("op-import-done")
		#expect(h.operations.operations.isEmpty)
		#expect(await h.settled())
		#expect(!h.stub.calls.contains("cancelOperation"))
		#expect(h.viewModel.presentedError == nil)
	}

	@Test func aRunningCardsCloseCancels() async {
		let h = await DesktopHarness.make()
		h.stub.ops = [Samples.copyOperation()]
		h.stub.emit(.operationChanged(op: Samples.copyOperation()))
		#expect(await eventually(timeout: .seconds(5)) {
			h.operations.operations.map(\.id) == ["op-1"]
		})
		h.viewModel.closeProgressCard("op-1")
		#expect(await eventually(timeout: .seconds(5)) {
			h.stub.calls.contains("cancelOperation")
		})
		#expect(h.stub.ops.isEmpty)
		#expect(h.viewModel.presentedError == nil)
	}

	// The operation ended between the card's last update and the click: the daemon answers
	// notFound, which is no failure of the user's.
	@Test func aCancelThatFindsTheOperationGoneStaysQuiet() async {
		let h = await DesktopHarness.make()
		h.stub.emit(.operationChanged(op: Samples.copyOperation()))   // not in stub.ops
		#expect(await eventually(timeout: .seconds(5)) {
			h.operations.operations.map(\.id) == ["op-1"]
		})
		h.viewModel.closeProgressCard("op-1")
		#expect(await eventually(timeout: .seconds(5)) {
			h.stub.calls.contains("cancelOperation")
		})
		#expect(await h.settled())
		#expect(h.viewModel.presentedError == nil)
	}

	@Test func aDismissedCardStaysGoneAfterAResync() async {
		let h = await DesktopHarness.make()
		h.stub.emit(.operationChanged(op: Samples.cancelledCopy()))
		#expect(await eventually(timeout: .seconds(5)) {
			h.operations.operations.map(\.id) == ["op-copy-cancelled"]
		})
		h.viewModel.closeProgressCard("op-copy-cancelled")
		#expect(h.operations.operations.isEmpty)
		// A reconnect while the daemon still lists it.
		h.stub.ops = [Samples.cancelledCopy()]
		let resyncs = h.stub.calls.filter { $0 == "operations" }.count
		h.operations.attach(api: h.stub)
		#expect(await eventually(timeout: .seconds(5)) {
			h.stub.calls.filter { $0 == "operations" }.count > resyncs
		})
		#expect(await h.settled())
		#expect(h.operations.operations.isEmpty)
	}

	// F7: work the engine can't stop shows no ✕; a stale click sends nothing and raises no
	// "cannot be cancelled" alert.
	@Test func aRunningCardThatCantCancelHasNoCancel() async {
		let h = await DesktopHarness.make()
		let op = Samples.rosettaInstallOperation()
		h.stub.ops = [op]
		h.stub.fail("cancelOperation", with: MachmanError(
			code: .invalidState, message: "operation '\(op.id)' cannot be cancelled"))
		h.stub.emit(.operationChanged(op: op))
		#expect(await eventually(timeout: .seconds(5)) {
			h.operations.operations.map(\.id) == [op.id]
		})
		h.viewModel.closeProgressCard(op.id)
		#expect(await h.settled())
		#expect(!h.stub.calls.contains("cancelOperation"))
		#expect(h.viewModel.presentedError == nil)
		#expect(h.operations.operations.map(\.id) == [op.id])
	}

	// A running install's card cancels the install.
	@Test func anInstallCardsCloseCancelsTheInstall() async {
		let h = await DesktopHarness.make()
		h.viewModel.closeProgressCard(VMListViewModel.installCardPrefix + "Sequoia")
		#expect(await eventually(timeout: .seconds(5)) {
			h.stub.calls.contains("cancelMacInstall")
		})
	}

	// MARK: - The cards themselves (Q33: decided in DesktopCore, not in the overlay's body)

	// Install cards came from iterating a Dictionary: two at once had no defined order.
	@Test("Q33: two installs ride as cards in name order, after the operations")
	func twoInstallsInNameOrder() async {
		let h = await DesktopHarness.make([
			Samples.macOS("Tahoe"), Samples.macOS("Sequoia"), Samples.linux("Debian"),
		])
		h.stub.emit(.operationChanged(op: Samples.copyOperation()))
		h.stub.emit(.installPhaseChanged(vm: "Tahoe", phase: Samples.installingMacInstall()))
		h.stub.emit(.installPhaseChanged(vm: "Sequoia", phase: Samples.downloadingMacInstall()))
		#expect(await eventually { h.operations.installPhases.count == 2 })
		#expect(await eventually { !h.operations.operations.isEmpty })
		let cards = h.operations.progressCards(now: Samples.now)
		#expect(cards.map(\.id) == ["op-1", "install:Sequoia", "install:Tahoe"])
		#expect(cards[1].title == "Sequoia \u{2014} Installing macOS")
		#expect(cards[1].phase == "Downloading macOS 15.4\u{2026}")
		#expect(cards[1].fraction == 0.25)
		#expect(cards[1].etaSeconds != nil)
		#expect(cards[2].phase == "Installing macOS 15.4\u{2026}")
		#expect(cards[2].cancellable && !cards[2].finished)
	}

	@Test("Q33: an operation's card says its bytes, Working… or its outcome")
	func anOperationsCardSaysWhereItIs() async {
		let h = await DesktopHarness.make()
		var counting = Samples.copyOperation()
		counting.completedBytes = 1 << 30
		counting.totalBytes = 4 << 30
		var unsized = Samples.copyOperation()
		unsized.id = "op-unsized"
		unsized.completedBytes = nil
		unsized.totalBytes = nil
		for op in [counting, unsized, Samples.finishedImport(), Samples.rosettaInstallOperation()] {
			h.stub.emit(.operationChanged(op: op))
		}
		#expect(await eventually { h.operations.operations.count == 4 })
		let cards = h.operations.progressCards(now: Samples.now)
		#expect(cards.map(\.phase).prefix(2) == [
			"\(ByteSize.display(1 << 30)) of \(ByteSize.display(4 << 30))", "Working\u{2026}",
		])
		let done = Samples.finishedImport()
		#expect(cards[2].phase == done.outcomeText)
		#expect(cards[2].finished)
		#expect(!cards[3].cancellable)   // work the engine can't stop shows no ✕ (F7)
	}
}

