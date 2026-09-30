import Testing
import MachmanAPI
import MachmanUI

struct VMTabStateTests {
	private func ref(_ k: SerialPortKind, _ i: Int) -> SerialPortRef {
		SerialPortRef(kind: k, index: i)
	}

	@Test func startsOnConfigWithNoTabs() {
		let s = VMTabState()
		#expect(s.openPorts.isEmpty)
		#expect(s.active == .config)
	}

	@Test func openAddsTabAndActivates() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		#expect(s.openPorts == [ref(.console, 0)])
		#expect(s.active == .terminal(ref(.console, 0)))
	}

	@Test func reopeningExistingFocusesWithoutDuplicating() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		s.open(ref(.uart, 0))
		s.activate(.config)
		s.open(ref(.console, 0))
		#expect(s.openPorts == [ref(.console, 0), ref(.uart, 0)])   // no dup
		#expect(s.active == .terminal(ref(.console, 0)))            // refocused
	}

	@Test func activateIgnoresUnopenedTerminal() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		s.activate(.terminal(ref(.uart, 9)))
		#expect(s.active == .terminal(ref(.console, 0)))   // unchanged
	}

	@Test func closingActiveFallsBackToRightNeighbour() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		s.open(ref(.uart, 0))
		s.open(ref(.uart, 1))
		s.activate(.terminal(ref(.uart, 0)))   // middle active
		s.close(ref(.uart, 0))
		#expect(s.openPorts == [ref(.console, 0), ref(.uart, 1)])
		#expect(s.active == .terminal(ref(.uart, 1)))   // the tab that slid into its slot
	}

	@Test func closingLastActiveFallsBackToLeftNeighbour() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		s.open(ref(.uart, 0))
		s.close(ref(.uart, 0))   // rightmost active
		#expect(s.active == .terminal(ref(.console, 0)))
	}

	@Test func closingOnlyTabFallsBackToConfig() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		s.close(ref(.console, 0))
		#expect(s.openPorts.isEmpty)
		#expect(s.active == .config)
	}

	@Test func closingInactiveKeepsActive() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		s.open(ref(.uart, 0))   // active
		s.close(ref(.console, 0))
		#expect(s.openPorts == [ref(.uart, 0)])
		#expect(s.active == .terminal(ref(.uart, 0)))   // unchanged
	}

	@Test func reconcileDropsVanishedPortsAndFixesActive() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		s.open(ref(.uart, 0))
		s.open(ref(.uart, 1))
		s.activate(.terminal(ref(.uart, 1)))
		let removed = s.reconcile(existing: [ref(.console, 0)])
		#expect(Set(removed) == [ref(.uart, 0), ref(.uart, 1)])
		#expect(s.openPorts == [ref(.console, 0)])
		#expect(s.active == .terminal(ref(.console, 0)))
	}

	@Test func reconcileToNothingFallsBackToConfig() {
		var s = VMTabState()
		s.open(ref(.console, 0))
		let removed = s.reconcile(existing: [])
		#expect(removed == [ref(.console, 0)])
		#expect(s.active == .config)
	}
}
