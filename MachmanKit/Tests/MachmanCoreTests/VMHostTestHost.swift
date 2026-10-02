//
//  VMHostTestHost.swift
//  MachmanTests
//
//  A vmhost's delegate and presenter with the AppKit edges replaced: prompts are recorded
//  and answered by `answer`, stops are recorded and fail as `refusals` says, and the
//  shutdown follow-up's grace passes at once (or when a GraceGate opens). The delegate's
//  server is never started — MachmanServer.init does not bind — so nothing listens.
//

import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

@MainActor
final class TestVMHost {
	let presenter: WindowPresenter
	let delegate: VMHostAppDelegate
	var running: Bool
	var answer: (HostPrompt) -> HostChoice
	var refusals: [StopMode: MachmanError] = [:]
	private(set) var prompts: [HostPrompt] = []
	private(set) var stops: [StopMode] = []

	init(
		running: Bool = true, presenter: WindowPresenter? = nil,
		answer: @escaping (HostPrompt) -> HostChoice = { _ in .cancel }
	) {
		self.running = running
		self.answer = answer
		let presenter = presenter ?? WindowPresenter()
		self.presenter = presenter
		delegate = VMHostAppDelegate(
			vmName: { "alpha" }, presenter: presenter,
			server: MachmanServer(
				api: StubMachman(),
				socketPath: TestEnvironment.scratch + "vmhost-\(UUID().uuidString).sock",
				daemonVersion: "test"))
		presenter.isRunning = { [unowned self] _ in self.running }
		presenter.stopHandler = { [unowned self] _, mode in
			self.stops.append(mode)
			if let refusal = self.refusals[mode] {
				throw refusal
			}
		}
		presenter.answerPrompt = { [unowned self] prompt in
			self.prompts.append(prompt)
			return self.answer(prompt)
		}
		presenter.softStopFollowUp.sleep = { _ in }
	}
}

// The follow-up's grace period, held open until the test lets it pass.
actor GraceGate {
	private var isOpen = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func open() {
		isOpen = true
		waiters.forEach { $0.resume() }
		waiters = []
	}
}
