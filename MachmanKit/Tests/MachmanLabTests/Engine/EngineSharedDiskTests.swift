//
//  EngineSharedDiskTests.swift
//  MachmanLabTests
//
//  L2 — two VMs that take turns on one writable image (E71). The start guard counted a VM
//  whose run was over as running until the agent heard its vmhost exit — the death watch or
//  the dropped connection, a moment after the VM listed stopped — and refused the other's
//  start "<VM> is running with <image> attached". Each turn force-stops the running VM and
//  starts the other at once: once the stop, its stopped state and its vmhost's exit are in
//  (wave r4w2's probe order), and the moment the stop returns.
//

import Foundation
import Testing
import MachmanAPI

@Suite("Engine — a disk shared in turns", .serialized, .enabled(if: Lab.runs(.l2)))
struct EngineSharedDiskTests {
	private static let headless = StartOptions(openWindow: false)

	/// Two Alpine VMs attaching one raw image, writable.
	private static func pair(_ agent: LabAgent) async throws -> (TGVM, TGVM) {
		let image = agent.scope.imagesDir + "/turns.img"
		try await TG.writeFile(image, size: 64 << 20)
		let a = try await TGVM.alpine("turns a", externals: [TGExternal(path: image)], on: agent)
		let b = try await TGVM.alpine("turns b", externals: [TGExternal(path: image)], on: agent)
		return (a, b)
	}

	/// The start's refusal, or nil once the VM runs.
	private static func refusal(starting vm: TGVM) async throws -> MachmanError? {
		do {
			try await vm.start(headless)
			return nil
		} catch let error as MachmanError {
			return error
		}
	}

	@Test("E71: a start right after a disk sharer's force stop and exit is never refused")
	func startAfterTheSharersExit() async throws {
		try await TG.withAgent { agent in
			var (running, next) = try await Self.pair(agent)
			try await running.start(Self.headless)
			let turns = 60
			var refused: [String] = []
			for turn in 1...turns {
				try await running.forceStop()   // the stop, its stopped state, the vmhost's exit
				if let error = try await Self.refusal(starting: next) {
					refused.append("\(turn): \(error.message)")
					try await Task.sleep(for: .seconds(1))   // counted; the next turn goes on
					try await next.start(Self.headless)
				}
				swap(&running, &next)
			}
			try await running.forceStop()
			// Fails until the open bug E71 (a start right after a disk sharer's force stop is
			// refused as if that VM still ran) is fixed.
			#expect(refused.isEmpty, "\(refused.count) of \(turns) starts refused: \(refused)")
		}
	}

	@Test("E71: a start sent the moment a disk sharer's force stop returns is never refused")
	func startTheMomentTheStopReturns() async throws {
		try await TG.withAgent { agent in
			var (running, next) = try await Self.pair(agent)
			try await running.start(Self.headless)
			let turns = 20
			var refused: [String] = []
			for turn in 1...turns {
				let host = try await running.hostPID()
				try await agent.api.stop(vm: running.name, mode: .force)
				let error = try await Self.refusal(starting: next)
				// The stopped VM's vmhost exits after its stop flush; its pid file goes then.
				try await running.stopped(host: host)
				if let error {
					refused.append("\(turn): \(error.message)")
					try await Task.sleep(for: .seconds(1))   // counted; the next turn goes on
					try await next.start(Self.headless)
				}
				swap(&running, &next)
			}
			try await running.forceStop()
			// Fails until the open bug E71 (a start right after a disk sharer's force stop is
			// refused as if that VM still ran) is fixed.
			#expect(refused.isEmpty, "\(refused.count) of \(turns) starts refused: \(refused)")
		}
	}
}
