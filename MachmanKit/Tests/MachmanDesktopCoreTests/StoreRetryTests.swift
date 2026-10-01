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

@MainActor
struct StoreRetryTests {
	private static let listTimeout = MachmanError(
		code: .timeout,
		message: "no reply to vm.list after 30s — the serving process may be hung")

	// No listChanged ever comes: only the store's own retry can load the list.
	@Test func aListThatFailedOnceLoadsWithoutAnEvent() async {
		let stub = StubMachman.serving(Samples.library())
		stub.fail("listVMs", with: Self.listTimeout)
		let store = VMStore()
		store.attach(api: stub)
		#expect(await eventually(timeout: .seconds(5)) {
			store.vms.count == Samples.library().count
		})
		#expect(store.listProblem == nil)
		store.detach()
	}

	@Test func aFailureShowsUntilAListLands() async {
		let stub = StubMachman.serving(Samples.library())
		stub.fail("listVMs", with: Self.listTimeout)
		let store = VMStore(retryDelays: [.seconds(30)])
		store.attach(api: stub)
		#expect(await eventually(timeout: .seconds(5)) { store.listProblem != nil })
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
			== ["Couldn't refresh the VM list — retrying"])
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
		let operations = OperationsStore()
		operations.attach(api: stub)
		#expect(await eventually(timeout: .seconds(5)) {
			operations.operations.map(\.id) == ["op-1"]
		})
		operations.detach()
	}

	@Test func aDetachedStoreStopsRetrying() async {
		let stub = StubMachman.serving(Samples.library())
		stub.fail("listVMs", with: Self.listTimeout)
		let store = VMStore(retryDelays: [.milliseconds(50)])
		store.attach(api: stub)
		#expect(await eventually(timeout: .seconds(5)) { store.listProblem != nil })
		store.detach()
		let calls = stub.calls.filter { $0 == "listVMs" }.count
		try? await Task.sleep(for: .milliseconds(300))
		#expect(stub.calls.filter { $0 == "listVMs" }.count == calls)
	}
}
