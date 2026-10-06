//
//  ListReloadTests.swift
//  MachmanDesktopCoreTests
//
//  How often the desktop fetches the VM list (P8). Every listChanged ran a whole fetch of
//  its own, one after another, and every SSH or setup report started one more beside them:
//  a burst of N events cost N fetches, each with its decode, reconcile and toast diff. And
//  fetches could overlap, so an older reply could land over a newer list. One fetch is in
//  flight at a time now; what is asked meanwhile is answered by the one after it.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct ListReloadTests {
	private func fetches(_ h: DesktopHarness) -> Int {
		h.stub.calls.filter { $0 == "listVMs" }.count
	}

	@Test("P8: a burst of list, SSH and setup events costs one fetch in flight and one after it")
	func aBurstCostsTwoFetches() async throws {
		let h = await DesktopHarness.make()
		let gate = ReplyGate()
		h.stub.pause = { method in
			if method == "listVMs" { await gate.wait() }
		}
		let before = fetches(h)
		h.stub.emit(.listChanged)
		#expect(await eventually { gate.held == 1 })
		let asked = h.store.asked
		for _ in 0..<6 { h.stub.emit(.listChanged) }
		h.stub.emit(.sshChanged(vm: "Debian"))
		h.stub.emit(.setupChanged(vm: "Debian"))
		#expect(await eventually { h.store.asked == asked + 8 })   // every event was heard
		#expect(gate.held == 1)   // nothing beside the fetch in flight
		gate.releaseAll()
		#expect(await eventually { gate.held == 1 })   // the one after it
		gate.open()
		#expect(await eventually { fetches(h) == before + 2 })
		try await Task.sleep(for: .milliseconds(100))
		#expect(fetches(h) == before + 2)
	}

	// The second reload asks after the list changed; its fetch must be the one that lands
	// last, however the replies are ordered.
	@Test("P8: an older list reply never replaces a newer one")
	func anOlderReplyNeverWins() async {
		let h = await DesktopHarness.make()
		let gate = ReplyGate()
		var calls = 0
		h.stub.pause = { method in
			guard method == "listVMs" else { return }
			calls += 1
			if calls == 1 { await gate.wait() }   // the first fetch's reply comes late
		}
		let first = Task { await h.store.reload() }
		#expect(await eventually { gate.held == 1 })
		h.stub.vms["Newcomer"] = Samples.linux("Newcomer")
		let second = Task { await h.store.reload() }
		// Lets a second fetch land, where one may start beside the first.
		_ = await eventually(timeout: .milliseconds(500)) {
			h.store.vms.contains { $0.name == "Newcomer" }
		}
		gate.open()
		await second.value
		#expect(h.store.vms.contains { $0.name == "Newcomer" })   // a list fetched after it asked
		await first.value
		#expect(h.store.vms.contains { $0.name == "Newcomer" })
	}

	// A fetch read Debian running; Debian stopped before its reply came. Its older list put
	// "running" back over the patch until the follow-up fetch landed: the state flipped for
	// one round trip and each flip toasted (review F6).
	@Test("P8: a state change during a fetch is never undone by its list")
	func aPatchOutlivesTheFetchItOvertook() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.toastLifetimeOverride = .seconds(60)
		let gate = ReplyGate()
		var calls = 0
		h.stub.pause = { method in
			guard method == "listVMs" else { return }
			calls += 1
			if calls == 1 { await gate.wait() }   // the fetch that read Debian running
		}
		var states: [VMState] = []
		let watch = h.store.$vms.sink { list in
			if let state = list.first(where: { $0.name == "Debian" })?.state {
				states.append(state)
			}
		}
		let before = fetches(h)
		h.stub.emit(.listChanged)
		#expect(await eventually { gate.held == 1 })
		h.stub.vms["Debian"]?.state = .stopped
		h.stub.emit(.stateChanged(vm: "Debian", state: .stopped))
		#expect(await eventually { h.store.vms.first { $0.name == "Debian" }?.state == .stopped })
		gate.open()
		#expect(await eventually { fetches(h) == before + 2 })   // the fetch and its follow-up
		try await Task.sleep(for: .milliseconds(100))
		watch.cancel()
		let stopped = try #require(states.firstIndex(of: .stopped))
		#expect(!states[stopped...].contains(.running), "\(states)")
		#expect(h.viewModel.toasts.filter { $0.message == "Debian stopped" }.count == 1)
		#expect(!h.viewModel.toasts.contains { $0.message == "Debian started" })
	}

	// A VM the list didn't hold yet started while a fetch was out, and the fetch read it
	// running. Its event patched no row, so nobody had seen "starting": laying it over the
	// list showed the older state first and toasted "started" on the follow-up (review F12).
	@Test("P8: a state change for a VM not yet listed leaves the landing list alone")
	func anUnlistedPatchIsNotLaidOver() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.toastLifetimeOverride = .seconds(60)
		let gate = ReplyGate()
		var calls = 0
		h.stub.pause = { method in
			guard method == "listVMs" else { return }
			calls += 1
			if calls == 1 { await gate.wait() }   // the fetch that read Newcomer running
		}
		var states: [VMState] = []
		let watch = h.store.$vms.sink { list in
			if let state = list.first(where: { $0.name == "Newcomer" })?.state {
				states.append(state)
			}
		}
		let before = fetches(h)
		h.stub.vms["Newcomer"] = Samples.linux("Newcomer", state: .running)
		h.stub.emit(.listChanged)
		#expect(await eventually { gate.held == 1 })
		let asked = h.store.asked
		h.stub.emit(.stateChanged(vm: "Newcomer", state: .starting))
		#expect(await eventually { h.store.asked == asked + 1 })   // the store heard it
		gate.open()
		#expect(await eventually { fetches(h) == before + 2 })   // the fetch and its follow-up
		try await Task.sleep(for: .milliseconds(100))
		watch.cancel()
		#expect(states.first == .running, "\(states)")
		#expect(!states.contains(.starting), "\(states)")
		#expect(!h.viewModel.toasts.contains { $0.message == "Newcomer started" })
	}
}
