//
//  SocketErrorTextTests.swift
//  MachmanTests
//
//  O-4: the agent's “Machman Agent can’t start” alert showed a socket failure as its log
//  line ("bind/listen failed: …", "socket path too long for sockaddr_un: …"). A person reads
//  a sentence now; the log keeps the path and the failing call.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct SocketErrorTextTests {
	@Test func aPersonReadsASentence() {
		#expect(MachmanError.userMessage(for: UDSError.pathTooLong("/tmp/x.sock"))
			== "Its socket path is too long")
		#expect(MachmanError.userMessage(for: UDSError.systemError("bind/listen", EADDRINUSE))
			== "Couldn’t open its socket: Address already in use")
		#expect(MachmanError.userMessage(for: UDSError.systemError("rename", EACCES))
			== "Couldn’t move its socket: Permission denied")
		#expect(MachmanError.userMessage(for: UDSError.alreadyRunning("/tmp/x.sock"))
			== "Another copy is already serving its socket")
	}

	@Test func theLogKeepsThePathAndTheCall() {
		#expect("\(UDSError.pathTooLong("/tmp/x.sock"))"
			== "socket path too long for sockaddr_un: /tmp/x.sock")
		#expect("\(UDSError.systemError("bind/listen", EADDRINUSE))"
			== "bind/listen failed: Address already in use")
		#expect("\(UDSError.alreadyRunning("/tmp/x.sock"))"
			== "another daemon is already serving /tmp/x.sock")
	}
}
