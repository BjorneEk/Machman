//
//  TGSafeCancelTests.swift
//  MachmanLabTests
//
//  L2 — a safe run canceled while it prepares: the shadow build of a 1 GiB image on a second
//  volume (a real byte copy, T20 a) is the window; the card's ✕, Stop and Force Stop each fail
//  the start as canceled, leave no run dir and start no vmhost.
//

import Foundation
import Testing
import MachmanAPI
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
					"tg-c24", externals: [TGExternal(path: big)], policy: Self.safeHeadless,
					on: agent)
				let events = await TGEvents.record(agent.api)
				defer { events.stop() }
				let mark = events.mark()
				let options = try await vm.info().startOptions(.plain)
				let api = agent.api
				let start = Task { try await api.start(vm: "tg-c24", options: options) }
				let progress = try await events.waitForMidCopy(vm: "tg-c24", after: mark)
				#expect(progress.copied < progress.total)
				switch how {
				case .cardClose:
					let op = try #require(Self.shadowBuild(events, vm: "tg-c24", after: mark))
					try await api.cancelOperation(id: op.id)
				case .stop:
					try await api.stop(vm: "tg-c24", mode: .soft)
				case .forceStop:
					try await api.stop(vm: "tg-c24", mode: .force)
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
					kind: OperationInfo.Kind.shadowBuild, vm: "tg-c24", after: mark).last
				#expect(last?.state == OperationInfo.State.cancelled)
				try await vm.waitForState(.stopped, timeout: .seconds(10))
				#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
				#expect(await !TG.isSocketLive(vm.socketPath))
				#expect(try await TG.vmhostPids(socketPath: vm.socketPath).isEmpty)
			}
		}
	}
}
