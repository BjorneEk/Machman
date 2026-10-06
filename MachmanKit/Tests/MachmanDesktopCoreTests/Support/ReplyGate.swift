//
//  ReplyGate.swift
//  MachmanDesktopCoreTests
//
//  Holds stub replies back until the test lets them go (StubMachman.pause): a reply still in
//  flight while events and other replies land, in the order the test needs.
//

import Foundation

@MainActor
final class ReplyGate {
	private var waiting: [CheckedContinuation<Void, Never>] = []
	private var isOpen = false

	// Replies held right now.
	var held: Int { waiting.count }

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { waiting.append($0) }
	}

	// Lets every held reply go, and every later one through.
	func open() {
		isOpen = true
		releaseAll()
	}

	// Lets the replies held so far go; later ones wait again.
	func releaseAll() {
		let held = waiting
		waiting = []
		for continuation in held { continuation.resume() }
	}
}
