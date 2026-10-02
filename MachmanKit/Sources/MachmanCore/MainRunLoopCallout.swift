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
			RunLoop.main.perform(inModes: [.common]) {
				MainActor.assumeIsolated {
					continuation.resume(returning: body())
				}
			}
		}
	}
}
