//
//  VMHostStopTests.swift
//  MachmanTests
//
//  V5: the vmhost's Stop menu, its close prompt and its quit prompt ask for a stop the same
//  way — a Shut Down is followed up after the grace period, and a stop the engine refuses
//  is said at once in an alert, not only in the log. Prompts are answered through the
//  presenter's seam (TestVMHost); the registry tests use a bare VMRuntime, no VZ.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct VMHostStopTests {
	private let refusal = MachmanError(
		code: .invalidState, message: "alpha cannot handle a shutdown request; use force stop")

	@Test func theStopMenuFollowsUpLikeTheClosePrompt() async {
		let host = TestVMHost { $0 == .notShutDownYet("alpha") ? .forceStop : .cancel }
		host.delegate.shutDown(nil)
		#expect(await eventually { host.stops == [.soft, .force] })
		#expect(host.prompts == [.notShutDownYet("alpha")])
	}

	@Test func keepWaitingLeavesTheGuestToIt() async {
		let host = TestVMHost { _ in .keepWaiting }
		host.delegate.shutDown(nil)
		#expect(await eventually { host.prompts == [.notShutDownYet("alpha")] })
		#expect(host.stops == [.soft])
	}

	@Test func theQuitPromptsShutDownFollowsUp() async {
		let host = TestVMHost { prompt in
			if prompt == .quitWhileRunning("alpha") { return .shutDown }
			return prompt == .notShutDownYet("alpha") ? .forceStop : .cancel
		}
		#expect(host.delegate.terminateReply() == .terminateCancel)
		#expect(await eventually { host.stops == [.soft, .force] })
		#expect(host.prompts == [.quitWhileRunning("alpha"), .notShutDownYet("alpha")])
	}

	@Test func aRefusedShutDownSaysSoAtOnce() async {
		let host = TestVMHost { $0 == .shutDownRefused("alpha") ? .forceStop : .cancel }
		host.refusals[.soft] = refusal
		host.delegate.shutDown(nil)
		#expect(await eventually { host.stops == [.soft, .force] })
		#expect(host.prompts == [.shutDownRefused("alpha")])   // no follow-up after a refusal
		#expect(!host.presenter.softStopFollowUp.isPending("alpha"))
	}

	@Test func aRefusedShutDownCanBeLeftRunning() async {
		let host = TestVMHost { _ in .cancel }
		host.refusals[.soft] = refusal
		host.delegate.shutDown(nil)
		#expect(await eventually { host.prompts == [.shutDownRefused("alpha")] })
		#expect(host.stops == [.soft])
	}

	@Test func aFailedForceStopSaysSo() async {
		let host = TestVMHost()
		host.refusals[.force] = MachmanError(code: .invalidState, message: "VZ said no.")
		host.delegate.forceStop(nil)
		#expect(await eventually {
			host.prompts == [.forceStopFailed("alpha", reason: "VZ said no.")]
		})
	}

	// Close Window (or the VM going away) ends the wait; a rename carries it along.
	@Test func closingTheWindowEndsTheFollowUp() async {
		let host = TestVMHost()
		let gate = GraceGate()
		host.presenter.softStopFollowUp.sleep = { _ in await gate.wait() }
		await host.presenter.requestShutDown("alpha")
		#expect(host.presenter.softStopFollowUp.isPending("alpha"))
		host.presenter.rekey(from: "alpha", to: "kept")
		#expect(host.presenter.softStopFollowUp.isPending("kept"))
		host.presenter.dropWindow(name: "kept")
		#expect(!host.presenter.softStopFollowUp.isPending("kept"))
		await gate.open()
	}

	// The registry's stop path hands the engine's refusal back to the vmhost's prompts.
	@Test func theRegistryHandsARefusalBack() async throws {
		let registry = try Self.hostRegistry()
		await #expect(throws: MachmanError.self) {
			try await registry.presenter.stopHandler?("alpha", .soft)
		}
	}

	@Test func theStopMenuShowsARegistryRefusal() async throws {
		let registry = try Self.hostRegistry()
		let engineStop = registry.presenter.stopHandler
		let host = TestVMHost(presenter: registry.presenter)
		registry.presenter.stopHandler = engineStop   // the registry's own stop path
		host.delegate.shutDown(nil)
		#expect(await eventually { host.prompts == [.shutDownRefused("alpha")] })
	}

	// A vmhost's one-VM registry whose VM has a bare runtime (no VZ): a soft stop is refused
	// before anything touches disk. Built inside the redirect, used outside it.
	private static func hostRegistry() throws -> VMRegistry {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let config = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try config.saveVMConfig()
			let registry = VMRegistry(only: "alpha")
			let vm = try #require(registry.vm(named: "alpha"))
			vm.runtime = VMRuntime(config: vm.config, events: registry.events)
			return registry
		}
	}
}
