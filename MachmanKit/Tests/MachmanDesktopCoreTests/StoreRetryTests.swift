//
//  StoreRetryTests.swift
//  MachmanDesktopCoreTests
//
//  P13: a VM list or operations pull that failed used to be dropped silently — the window
//  kept the old (or an empty) list until some unrelated event happened to reload it. Now the
//  stores retry on their own, and the view model shows a stale list as one status toast.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Q7: the retry tests ran on the standard 1/2/5 s back-off inside 5 s windows, which left
// 4 s of slack that a machine at load ~19 used up. They retry after 50 ms now and wait up to
// eventually's default 10 s.
@MainActor
struct StoreRetryTests {
	private static let listTimeout = MachmanError(
		code: .timeout,
		message: "no reply to vm.list after 30s — the serving process may be hung")

	// No listChanged ever comes: only the store's own retry can load the list.
	@Test func aListThatFailedOnceLoadsWithoutAnEvent() async {
		let stub = StubMachman.serving(Samples.library())
		stub.fail("listVMs", with: Self.listTimeout)
		let store = VMStore(retryDelays: [.milliseconds(50)])
		store.attach(api: stub)
		#expect(await eventually { store.vms.count == Samples.library().count })
		#expect(store.listProblem == nil)
		store.detach()
	}

	@Test func aFailureShowsUntilAListLands() async {
		let stub = StubMachman.serving(Samples.library())
		stub.fail("listVMs", with: Self.listTimeout)
		let store = VMStore(retryDelays: [.seconds(30)])
		store.attach(api: stub)
		#expect(await eventually { store.listProblem != nil })
		#expect(store.vms.isEmpty)
		await store.reload()
		#expect(store.listProblem == nil)
		#expect(store.vms.count == Samples.library().count)
		store.detach()
	}

	@Test func theViewModelShowsTheStaleListAsOneToast() async {
		let h = await DesktopHarness.make()
		#expect(h.viewModel.statusToasts.isEmpty)
		h.stub.fail("listVMs", with: Self.listTimeout)
		await h.store.reload()
		#expect(h.viewModel.statusToasts.map(\.message)
			== [VMListViewModel.listProblemMessage])
		#expect(h.viewModel.statusToasts.first?.id == VMListViewModel.listProblemToastID)
		#expect(h.viewModel.statusToasts.first?.sticky == true)
		#expect(h.viewModel.vms.count == Samples.library().count)   // the last good list stays
		await h.store.reload()
		#expect(h.viewModel.statusToasts.isEmpty)
	}

	@Test func operationsResyncRetries() async {
		let stub = StubMachman.serving(Samples.library())
		stub.ops = [Samples.copyOperation()]
		stub.fail("operations", with: MachmanError(
			code: .timeout, message: "no reply to host.operations after 30s"))
		let operations = OperationsStore(retryDelays: [.milliseconds(50)])
		operations.attach(api: stub)
		#expect(await eventually { operations.operations.map(\.id) == ["op-1"] })
		operations.detach()
	}

	@Test func aDetachedStoreStopsRetrying() async {
		let stub = StubMachman.serving(Samples.library())
		stub.fail("listVMs", with: Self.listTimeout)
		let store = VMStore(retryDelays: [.milliseconds(50)])
		store.attach(api: stub)
		#expect(await eventually { store.listProblem != nil })
		store.detach()
		let calls = stub.calls.filter { $0 == "listVMs" }.count
		// Waits out the 50 ms retry a detached store must not run: a timer, which settled()
		// doesn't wait for by design (Q34), so this check keeps its sleep.
		try? await Task.sleep(for: .milliseconds(300))
		#expect(stub.calls.filter { $0 == "listVMs" }.count == calls)
	}

	// Q32: the stores' one retry mechanism. Asked twice while waiting, it retries once; the
	// retry has cleared itself when it runs, so it can schedule the next; a reset drops a
	// pending retry and starts the waits over.
	@Test("Q32: one retry is pending at a time, cleared before it runs, reset by a success")
	func oneRetryPendingAtATime() async {
		let retry = RetryScheduler(delays: [.milliseconds(20), .seconds(30)])
		var runs = 0
		var pendingWhileRunning: Bool?
		retry.schedule {
			runs += 1
			pendingWhileRunning = retry.isPending
		}
		retry.schedule { runs += 100 }
		#expect(retry.isPending)
		#expect(await eventually { runs == 1 })
		#expect(pendingWhileRunning == false)
		#expect(!retry.isPending)
		// The second wait is the long one; a reset drops it and the first wait comes back.
		retry.schedule { runs += 100 }
		#expect(retry.isPending)
		retry.reset()
		#expect(!retry.isPending)
		retry.schedule { runs += 1 }
		#expect(await eventually { runs == 2 })
	}
}
