//
//  TGSafeCancelTests.swift
//  MachmanLabTests
//
//  L2 — a safe run canceled while it prepares: the shadow build of a 1 GiB image on a second
//  volume (a real byte copy, T20 a) is the window; the card's ✕, Stop and Force Stop each fail
//  the start as canceled, leave no run dir and start no vmhost, and neither the desktop nor
//  the agent raises an alert for it.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanDesktopCore
import MachmanTestSupport
import MachmanUI

enum TGCancel: String, CaseIterable, Sendable, CustomTestStringConvertible {
	case cardClose = "✕"
	case stop = "Stop"
	case forceStop = "Force Stop"

	var testDescription: String { rawValue }
}

@Suite("Safe-run cancel", .serialized, .enabled(if: Lab.runs(.l2) && TGVolume.enabled))
struct TGSafeCancelTests {
	static let safeHeadless = StartPolicy(windowed: false, safe: true)
	static let canceled = "The safe run was canceled"
	static let tooLate = "the copy finished before the cancel landed (T20: add the shadow hold)"

	/// Card V14, the agent menu during a safe run's preparation (r3-tg, V/BUG).
	static let agentMenuCard = Comment(rawValue: "V14: The agent menu lists a VM preparing a "
		+ "safe run as stopped: Shut Down and Force Stop stay off")

	static func shadowBuild(_ events: TGEvents, vm: String, after mark: Int) -> OperationInfo? {
		events.operations(kind: OperationInfo.Kind.shadowBuild, vm: vm, after: mark).first
	}

	@Test(
		"R3W2-24: canceling a safe-run preparation fails the start and leaves no run dir",
		arguments: TGCancel.allCases)
	func cancelPreparation(_ how: TGCancel) async throws {
		try await TGVolume.with(sizeGiB: 3) { volume in
			let big = try await volume.bigImage()
			try await TG.withAgent { agent in
				let vm = try await TGVM.alpine(
					"canceled-prep", externals: [TGExternal(path: big)], policy: Self.safeHeadless,
					on: agent)
				let events = await TGEvents.record(agent.api)
				defer { events.stop() }
				let mark = events.mark()
				let options = try await vm.info().startOptions(.plain)
				let api = agent.api
				let start = Task { try await api.start(vm: "canceled-prep", options: options) }
				let progress = try await events.waitForMidCopy(vm: "canceled-prep", after: mark)
				#expect(progress.copied < progress.total)
				switch how {
				case .cardClose:
					let op = try #require(
						Self.shadowBuild(events, vm: "canceled-prep", after: mark))
					try await api.cancelOperation(id: op.id)
				case .stop:
					try await api.stop(vm: "canceled-prep", mode: .soft)
				case .forceStop:
					try await api.stop(vm: "canceled-prep", mode: .force)
				}
				let outcome = await start.result
				guard case .failure(let error) = outcome else {
					Issue.record("the start succeeded: \(Self.tooLate)")
					try await vm.forceStop()
					return
				}
				let failure = error as? MachmanError
				#expect(failure?.code == .cancelled)
				#expect(failure?.message == Self.canceled)
				try await events.waitFor(after: mark) {
					guard case .operationChanged(let op) = $0 else { return false }
					return op.kind == OperationInfo.Kind.shadowBuild && op.isFinished
				}
				let last = events.operations(
					kind: OperationInfo.Kind.shadowBuild, vm: "canceled-prep", after: mark).last
				#expect(last?.state == OperationInfo.State.cancelled)
				try await vm.waitForState(.stopped, timeout: .seconds(10))
				#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
				#expect(await !TG.isSocketLive(vm.socketPath))
				#expect(try await TG.vmhostPids(socketPath: vm.socketPath).isEmpty)
			}
		}
	}

	@Test("R3W2-48: Stop during a safe-run preparation raises no alert in the desktop or agent")
	func stopDuringPreparationRaisesNoAlert() async throws {
		try await TGVolume.with(sizeGiB: 3) { volume in
			let big = try await volume.bigImage()
			try await TG.withAgent { agent in
				let vm = try await TGVM.alpine(
					"stopped-prep", externals: [TGExternal(path: big)], policy: Self.safeHeadless,
					on: agent)
				let events = await TGEvents.record(agent.api)
				defer { events.stop() }
				// The desktop: Start Safe, then Stop while it prepares.
				try await Self.desktopStopsPreparation(vm: vm, agent: agent, events: events)
				#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
				// The agent menu: Start Safe, then Shut Down while it prepares. The menu
				// lists the VM stopped until its vmhost starts, so its Shut Down is off then;
				// the desktop's Stop (the wire's) stops it instead.
				let mark = LabLog.mark()
				let index = events.mark()
				#expect(try await SeamProbe.control(agent, "menu startSafe stopped-prep") == "ok")
				try await events.waitForMidCopy(vm: "stopped-prep", after: index)
				let menu = try await agent.control("menu shutDown stopped-prep")
				withKnownIssue(Self.agentMenuCard) {
					#expect(menu == "ok")
				}
				if menu != "ok" { try await agent.api.stop(vm: "stopped-prep", mode: .soft) }
				try await Self.waitForCanceledBuild(events, vm: "stopped-prep", after: index)
				try await vm.waitForState(.stopped, timeout: .seconds(30))
				// The menu's start failed as canceled by now; an alert for it would be logged.
				try await Task.sleep(for: .seconds(2))
				#expect(LabLog.count("test prompt agent\\.actionFailed", after: mark) == 0)
				#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			}
		}
	}

	static func waitForCanceledBuild(_ events: TGEvents, vm: String, after mark: Int)
		async throws {
		try await events.waitFor(after: mark) {
			guard case .operationChanged(let op) = $0 else { return false }
			return op.kind == OperationInfo.Kind.shadowBuild && op.vm == vm && op.isFinished
		}
		let last = events.operations(
			kind: OperationInfo.Kind.shadowBuild, vm: vm, after: mark).last
		#expect(last?.state == OperationInfo.State.cancelled, "\(Self.tooLate)")
	}

	@MainActor
	static func desktopStopsPreparation(vm: TGVM, agent: LabAgent, events: TGEvents)
		async throws {
		let desktop = try await TGDesktop.make(
			api: agent.api, scope: agent.scope, showing: vm.name)
		let model = try #require(desktop.viewModel)
		let index = events.mark()
		let mark = LabLog.mark()
		model.startPolicyDriven(try #require(desktop.vm(vm.name)), .safe)
		try await events.waitForMidCopy(vm: vm.name, after: index)
		model.stopVM(vm.name, mode: .soft)
		try await waitForCanceledBuild(events, vm: vm.name, after: index)
		#expect(await desktop.waitFor(vm.name, .stopped))
		#expect(await eventually(timeout: .seconds(20)) { !model.isStartPending(vm.name) })
		// What the canceled start would have raised, it raises right as it fails.
		try await Task.sleep(for: .seconds(1))
		#expect(model.presentedError == nil)
		#expect(model.pendingForceStart == nil)
		#expect(LabLog.count("Starting \u{201C}\(vm.name)\u{201D} failed", after: mark) == 0)
		#expect(LabLog.count("Shutting down \u{201C}\(vm.name)\u{201D} failed", after: mark) == 0)
	}
}
