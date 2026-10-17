//
//  VMListViewModel+Runner.swift
//  MachmanDesktopCore
//
//  The one shape every request to the daemon runs in (Q1): how it goes out, and what it
//  says when it succeeds or is refused, decided here once — perform for a click, performEach
//  for a batch, attempt for an awaited outcome. The requests themselves live in +Actions.
//

import Foundation
import MachmanUI
import MachmanAPI

// What an action toasts when it went through.
struct ActionToast {
	let symbol: String
	let message: String
}

// What an action refreshes once its call went through, before its `refreshed` step: the VM
// list, so the affordances flip straight to the new state, or the host's capabilities.
enum ActionRefresh {
	case list
	case capabilities
}

extension VMListViewModel {
	// The one shape a request to the daemon runs in. The call goes out off the click, on the
	// api alone: a view model that went with its connection sends nothing, and a call in
	// flight doesn't keep it alive. A success runs `then` with the reply, `refresh` (holding
	// only the store), `refreshed`, then shows `toast`. A refusal runs `failed` first
	// (undoing what the click set up), then `recover` may answer a MachmanError that isn't a
	// failure (true: nothing more is said); anything else goes to the field that asked
	// (`refused`) or to an alert titled "<action> failed". Every step after an await runs
	// only while the view model is still here.
	func perform<Value>(
		_ action: String, toast: ActionToast? = nil,
		refused: (@MainActor (String) -> Void)? = nil,
		refresh: ActionRefresh? = nil,
		failed: (@MainActor (VMListViewModel) -> Void)? = nil,
		recover: (@MainActor (VMListViewModel, MachmanError) -> Bool)? = nil,
		_ call: @escaping @MainActor (any MachmanControlling) async throws -> Value,
		then: (@MainActor (VMListViewModel, Value) -> Void)? = nil,
		refreshed: (@MainActor (VMListViewModel, Value) -> Void)? = nil
	) {
		Task { [weak self] in
			guard let api = self?.api else { return }
			let value: Value
			do {
				value = try await call(api)
			} catch {
				guard let self else { return }
				failed?(self)
				if let error = error as? MachmanError, recover?(self, error) == true { return }
				self.refuse(error, while: action, to: refused)
				return
			}
			guard let store = self?.store else { return }
			if let self { then?(self, value) }
			switch refresh {
			case .list?: await store.reload()
			case .capabilities?: await store.refreshCapabilities()
			case nil: break
			}
			guard let self else { return }
			refreshed?(self, value)
			if let toast { self.pushToast(symbol: toast.symbol, message: toast.message) }
		}
	}

	// A batch, one item after another in one task (one disk-heavy copy at a time): a refused
	// item gets its own alert, titled by `action` for that item, and the rest carry on; `then`
	// hears how many went through. A view model that went stops the batch.
	func performEach<Item>(
		_ items: [Item], action: @escaping (Item) -> String,
		_ call: @escaping @MainActor (any MachmanControlling, Item) async throws -> Void,
		then: (@MainActor (VMListViewModel, Int) -> Void)? = nil
	) {
		Task { [weak self] in
			var succeeded = 0
			for item in items {
				guard let api = self?.api else { return }
				do {
					try await call(api, item)
					succeeded += 1
				} catch {
					self?.refuse(error, while: action(item), to: nil)
				}
			}
			guard let self else { return }
			then?(self, succeeded)
		}
	}

	// The awaited form, for a caller that needs the outcome: the reply, or nil once the
	// refusal went to the field that asked or to an alert. Its callers are the view model's
	// own async methods, which hold it for the call as they always did.
	func attempt<Value>(
		_ action: String, refused: (@MainActor (String) -> Void)? = nil,
		_ call: @MainActor (any MachmanControlling) async throws -> Value
	) async -> Value? {
		do {
			return try await call(api)
		} catch {
			refuse(error, while: action, to: refused)
			return nil
		}
	}
}
