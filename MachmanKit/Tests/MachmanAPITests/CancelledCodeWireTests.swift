//
//  CancelledCodeWireTests.swift
//  MachmanAPITests
//
//  Review F11: a safe start the user stopped while it prepared came back as an ioFailure,
//  shown as "Starting … failed". It carries its own code now, `cancelled` (additive: an older
//  client reads it as internalError, as it read any unknown code), so clients take it as a
//  never-mind. The raw value is wire contract from here on.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport

struct CancelledCodeWireTests {
	@Test func theCancelledCodeRoundTrips() throws {
		let error = MachmanError(code: .cancelled, message: "The safe run was canceled")
		let body = RPCErrorBody(error)
		#expect(body.data?.machmanCode == "cancelled")
		#expect(body.machmanError == error)
		let decoded = try JSONDecoder().decode(
			MachmanError.self, from: Data(#"{"code":"cancelled","message":"m"}"#.utf8))
		#expect(decoded.code == .cancelled)
	}
}
