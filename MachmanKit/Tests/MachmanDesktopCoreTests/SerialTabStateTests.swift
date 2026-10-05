//
//  SerialTabStateTests.swift
//  MachmanDesktopCoreTests
//
//  Why a serial tab has no terminal (T10): an open or restored tab keyed its placeholder on
//  the socket alone, so a disabled port or a gated UART on a running VM read "Start the VM to
//  open X." Each state now names what to do.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
@testable import MachmanDesktopCore

struct SerialTabStateTests {
	private let console = SerialPortRef(kind: .console, index: 0)
	private let uart = SerialPortRef(kind: .uart, index: 0)

	// Q12: the one lookup every tab, title, inspector and tree row uses.
	@Test func aPortIsFoundByItsRef() {
		let vm = Samples.kernelBoot()
		#expect(vm.port(for: console)?.kind == .console)
		#expect(vm.port(for: uart)?.guestDevice == vm.uartPorts?.first?.guestDevice)
		#expect(vm.port(for: SerialPortRef(kind: .console, index: 1)) == nil)
		#expect(Samples.bareLinux().port(for: console) == nil)
	}

	@Test func aLiveSocketWins() {
		let vm = Samples.linux("Debian", state: .running)
		#expect(SerialTabState(vm: vm, ref: console)
			== .live(socketPath: "\(Samples.sockets)/Debian-console0.sock"))
	}

	@Test func aStoppedVMAsksForAStart() {
		#expect(SerialTabState(vm: Samples.linux(), ref: console) == .startVM)
		// A port the list no longer has (a restored tab) reads the same.
		#expect(SerialTabState(vm: Samples.linux(), ref: uart) == .startVM)
	}

	@Test func aStartingVMWaits() {
		#expect(SerialTabState(vm: Samples.kernelBoot(state: .starting), ref: uart) == .waiting)
	}

	@Test func aPortEnabledAfterTheStartAsksForARestart() {
		#expect(SerialTabState(vm: Samples.consoleEnabledAfterStart(), ref: console)
			== .restartVM)
	}

	@Test func aDisabledPortOnARunningVMSaysSo() {
		#expect(SerialTabState(vm: Samples.disabledConsole(), ref: console)
			== .disabled(running: true))
		#expect(SerialTabState(vm: Samples.disabledConsole(state: .stopped), ref: console)
			== .disabled(running: false))
	}

	@Test func aGatedUARTSaysWhy() throws {
		let vm = Samples.gatedUART()
		let reason = try #require(vm.uartPorts?.first?.unavailable?.message)
		#expect(SerialTabState(vm: vm, ref: uart) == .unavailable(reason: reason))
		#expect(SerialTabState(vm: Samples.gatedUART(state: .stopped), ref: uart)
			== .unavailable(reason: reason))
	}

	// A port disabled while the VM runs keeps its bridge until the stop: still live.
	@Test func aPortDisabledMidRunStaysLive() {
		var vm = Samples.linux("Debian", state: .running)
		vm.consolePorts?[0].enabled = false
		guard case .live = SerialTabState(vm: vm, ref: console) else {
			Issue.record("expected a live tab")
			return
		}
	}
}
