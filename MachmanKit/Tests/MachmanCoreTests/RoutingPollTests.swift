//
//  RoutingPollTests.swift
//  MachmanCoreTests
//
//  Q36: the host supervisor waited in five hand-rolled loops on two clocks — Date deadlines
//  in the quit path's stop-all, a counted 40 × 250 ms loop in the spawn, ContinuousClock in
//  the rest. They share one poll now. Q40: that poll, and every retry timer and grace of the
//  host table, runs on the router's clock — ContinuousClock, or a test's that it moves by hand.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct RoutingPollTests {
	@MainActor
	private func makeRouting() throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		return routing
	}

	@Test("Q36: poll looks until its condition holds or its time is up, and says which")
	@MainActor func pollLooksUntilItsConditionHoldsOrItsTimeIsUp() async throws {
		let routing = try makeRouting()
		var looks = 0
		let held = await routing.poll(every: .milliseconds(10), for: .seconds(30)) {
			looks += 1
			return looks == 3
		}
		#expect(held)
		#expect(looks == 3)

		// Already over: one look, no wait.
		looks = 0
		#expect(await routing.poll(every: .seconds(30), for: .seconds(30)) {
			looks += 1
			return true
		})
		#expect(looks == 1)

		// Out of time: false, after looking at least once more past the first.
		looks = 0
		let clock = ContinuousClock()
		let started = clock.now
		let timedOut = await routing.poll(every: .milliseconds(20), for: .milliseconds(200)) {
			looks += 1
			return false
		}
		#expect(!timedOut)
		#expect(looks > 1)
		#expect(clock.now - started >= .milliseconds(200))

		// A throw ends the wait at once.
		struct Stop: Error {}
		looks = 0
		await #expect(throws: Stop.self) {
			_ = try await routing.poll(every: .milliseconds(10), for: .seconds(30)) {
				looks += 1
				if looks == 2 { throw Stop() }
				return false
			}
		}
		#expect(looks == 2)
	}

	@Test("Q40: poll gives up only once the router's clock passes its timeout")
	@MainActor func pollGivesUpOnTheRoutersClock() async throws {
		let routing = try makeRouting()
		let clock = TestClock()
		routing.clock = clock
		var looks = 0
		let wait = Task { @MainActor in
			await routing.poll(every: .milliseconds(100), for: .milliseconds(250)) {
				looks += 1
				return false
			}
		}
		#expect(await eventually { clock.armed == [.milliseconds(100)] })
		clock.advance(by: .milliseconds(100))
		#expect(await eventually { looks == 2 && clock.armed == [.milliseconds(100)] })
		clock.advance(by: .milliseconds(100))
		#expect(await eventually { looks == 3 && clock.armed == [.milliseconds(100)] })
		clock.advance(by: .milliseconds(100))   // 300 ms: past its 250
		#expect(await wait.value == false)
		#expect(looks == 4)
	}

	@Test(
		"""
		Q36: the host supervisor's waits share one poll, never a Date deadline or a counted \
		loop
		""")
	func theHostSupervisorsWaitsPollOnOneClock() throws {
		let files = [
			"Supervisor", "Spawn", "Liveness", "Adoption",
		].map { "MachmanKit/Sources/MachmanCore/RoutingMachman+\($0).swift" }
		let dated = try SourceScan.hits(#"Date\(\)\.addingTimeInterval"#, in: files)
		#expect(dated.isEmpty, "wait with poll(every:for:until:): \(dated)")
		let counted = try SourceScan.hits(#"for _ in 0\.\.<"#, in: files)
		#expect(counted.isEmpty, "wait with poll(every:for:until:): \(counted)")
	}

	// Q40: a wait or timer of the host table on a clock of its own is one a test can't move:
	// its check could only measure wall time, which load stretches.
	@Test("Q40: the host supervisor's waits and retry timers sleep on the router's clock")
	func theHostSupervisorsTimersSleepOnTheRoutersClock() throws {
		let files = [
			"Supervisor", "Spawn", "Liveness", "Adoption", "StartupReconciler",
		].map { "MachmanKit/Sources/MachmanCore/RoutingMachman+\($0).swift" }
		let own = try SourceScan.hits(#"Task\.sleep\(|ContinuousClock\(\)"#, in: files)
		#expect(own.isEmpty, "sleep and measure on the router's clock: \(own)")
	}
}
