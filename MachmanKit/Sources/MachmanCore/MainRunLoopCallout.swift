//
//  MainRunLoopCallout.swift
//  MachmanCore
//
//  Where a modal alert asked from a Task runs. NSAlert.runModal spins a nested run loop, and
//  one spun inside a main-queue job (every main-actor Task is one) leaves the main queue
//  undrained until it returns: every other main-actor job waits behind the alert, and in the
//  daemon or a vmhost that is the socket server's request handling. Started from a run-loop
//  callout instead, the nested loop drains the main queue as the app's own loop does, so the
//  server keeps answering while the alert shows. Prompts AppKit asks for itself (a window's
//  close button, a quit) arrive from event dispatch and need none of this.
//

import Foundation

public enum MainRunLoopCallout {
	// Runs `body` from a main run-loop callout in the common modes, so it also runs under menu
	// tracking or another modal, and hands its result back to the awaiting caller.
	@MainActor
	public static func run<T>(_ body: @escaping @MainActor () -> T) async -> T {
		await withCheckedContinuation { continuation in
			post { continuation.resume(returning: body()) }
		}
	}

	// A loop nested inside a main-actor job runs callouts too: a synchronous Process wait
	// (ssh-keygen writing a guest setup payload) spins one. A modal from there would hold the
	// main queue after all, so the work waits for that job to end and is posted again.
	// Internal for tests.
	@MainActor
	static func post(_ work: @escaping @MainActor () -> Void) {
		RunLoop.main.perform(inModes: [.common]) {
			MainActor.assumeIsolated {
				if withUnsafeCurrentTask(body: { $0 != nil }) {
					Task { @MainActor in post(work) }
				} else {
					work()
				}
			}
		}
	}
}
