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
		try? await Task.sleep(for: .milliseconds(300))
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
		try? await Task.sleep(for: .milliseconds(300))
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
		try? await Task.sleep(for: .milliseconds(300))
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
		try? await Task.sleep(for: .milliseconds(300))
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
}
