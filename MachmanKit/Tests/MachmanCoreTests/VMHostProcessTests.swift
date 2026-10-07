//
//  VMHostProcessTests.swift
//  MachmanCoreTests
//
//  E61: a socket whose connects are refused is asked about from outside — is a vmhost launched
//  to serve it (its executable, its --socket argument) still alive? The lookup's parts, read
//  off this test process, and what the socket probes make of its answer. No vmhost runs here.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct VMHostProcessTests {
	@Test("E61: a process's arguments read from outside are the ones it was launched with")
	func argumentsReadFromOutsideMatch() {
		#expect(VMHostProcess.arguments(of: getpid()) == CommandLine.arguments)
	}

	@Test("E61: the socket a vmhost serves is the path after its --socket")
	func theServedSocketIsItsSocketArgument() {
		let argv = [
			"/Applications/Machman.app/Contents/MacOS/MachmanVMHost",
			"--data-dir", "/d", "--vm", "dev", "--socket", "/t/vm-1.sock",
		]
		#expect(VMHostProcess.socketArgument(argv) == "/t/vm-1.sock")
		#expect(VMHostProcess.socketArgument(Array(argv.dropLast())) == nil)
		#expect(VMHostProcess.socketArgument(Array(argv.prefix(5))) == nil)
	}

	@Test("E61: a socket file no vmhost was launched for reads dead when it refuses")
	func aRefusingSocketNoVMHostServesReadsDead() {
		let path = TestEnvironment.socketPath("mm-dead")
		FileManager.default.createFile(atPath: path, contents: nil)   // a SIGKILL leftover
		defer { unlink(path) }
		#expect(VMHostProcess.serving(socketPath: path) == nil)
		#expect(!UDSListener.isLive(path: path))
		#expect(UDSListener.holderPID(path: path) == nil)
	}

	@Test("E61: a refusing socket a live vmhost was launched for reads live and stays")
	func aRefusingSocketAVMHostServesReadsLive() {
		let path = TestEnvironment.socketPath("mm-frozen")
		FileManager.default.createFile(atPath: path, contents: nil)   // refuses every connect
		defer { unlink(path) }
		VMHostProcess.TestHook.setServing(path, getpid())   // this process plays the vmhost
		defer { VMHostProcess.TestHook.setServing(path, nil) }
		#expect(UDSListener.isLive(path: path))
		#expect(UDSListener.holderPID(path: path) == getpid())
		#expect(BoundSocket.removeIfDead(path) == .live)
		#expect(FileManager.default.fileExists(atPath: path))
	}
}
