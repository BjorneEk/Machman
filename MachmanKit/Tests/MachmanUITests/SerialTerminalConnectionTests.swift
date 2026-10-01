//
//  SerialTerminalConnectionTests.swift
//  MachmanUITests
//
//  The serial tabs' socket client against a test-owned unix socket standing in for the
//  vmhost's bridge (TerminalStreamSupport) — no daemon, no VM.
//

import Testing
import Foundation
@testable import MachmanUI
import MachmanTestSupport

@MainActor
struct SerialTerminalConnectionTests {

	@Test func bytesFlowBothWaysAndAHangUpEndsTheStream() async throws {
		let peer = try SocketPeer()
		defer { peer.close() }
		let stream = SerialTerminalConnection(path: peer.path)
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		stream.onClose = { sink.markClosed() }
		defer { stream.stop() }
		#expect(stream.connect())
		#expect(await eventually { peer.client >= 0 })
		peer.startDraining(keep: true)
		stream.send(Data("ping".utf8))
		#expect(await eventually { peer.drainedData == Data("ping".utf8) })
		peer.write(Data("BYE".utf8))
		peer.hangUp()
		#expect(await eventually { sink.isClosed })
		#expect(sink.textWhenClosed == "BYE")
		#expect(stream.transcriptData() == Data("BYE".utf8))
	}

	@Test func aMissingSocketFailsToConnect() {
		let stream = SerialTerminalConnection(path: TestEnvironment.scratch + "nobody.sock")
		#expect(!stream.connect())
		stream.send(Data("x".utf8))   // safe while unconnected
		stream.stop()
	}
}
