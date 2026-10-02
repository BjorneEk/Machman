//
//  SoftStopEscalation.swift
//  MachmanCore
//
//  The one "hasn't shut down yet" follow-up behind every Shut Down the vmhost offers — the
//  Stop menu, the window's close prompt, the quit and logout prompts: a guest that ignores
//  the request is offered a force stop once the grace period is over. One per VM; closing
//  its window or renaming it (Save as New VM) carries through.
//

import Foundation

@MainActor
final class SoftStopEscalation {
	// Test seams: the grace period and how it is waited out.
	var grace: Duration = .seconds(30)
	var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
	// Wiring (WindowPresenter): whether the VM still runs, the question, the force stop.
	var isRunning: (String) -> Bool = { _ in false }
	var askToForce: (String) async -> Bool = { _ in false }
	var force: (String) -> Void = { _ in }

	// A class, so a rename reaches the wait already in flight.
	private final class Entry {
		var name: String
		var task: Task<Void, Never>?

		init(name: String) {
			self.name = name
		}
	}
	private var pending: [Entry] = []

	func isPending(_ name: String) -> Bool {
		pending.contains { $0.name == name }
	}

	// A second Shut Down while one is pending adds nothing: one follow-up per VM. Returns the
	// wait, or nil when one was already pending.
	@discardableResult
	func schedule(_ name: String) -> Task<Void, Never>? {
		guard !isPending(name) else { return nil }
		let entry = Entry(name: name)
		pending.append(entry)
		entry.task = Task { [weak self, weak entry, grace, sleep] in
			await sleep(grace)
			guard let self, let entry, !Task.isCancelled,
				self.pending.contains(where: { $0 === entry }) else {
				return
			}
			// Pending while it asks, so a rename (Save as New VM) still reaches it and a second
			// Shut Down still adds none. Checked again after the answer, under the name then
			// current: the guest can finish, or the VM be renamed, while the question shows.
			defer { self.pending.removeAll { $0 === entry } }
			if self.isRunning(entry.name), await self.askToForce(entry.name),
				self.isRunning(entry.name) {
				self.force(entry.name)
			}
		}
		return entry.task
	}

	func cancel(_ name: String) {
		for entry in pending where entry.name == name {
			entry.task?.cancel()
		}
		pending.removeAll { $0.name == name }
	}

	func rekey(from oldName: String, to newName: String) {
		for entry in pending where entry.name == oldName {
			entry.name = newName
		}
	}
}
