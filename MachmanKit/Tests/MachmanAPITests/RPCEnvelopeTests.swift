import Testing
import Foundation
import MachmanAPI

// Golden fixtures for the JSON-RPC envelope — the framing every client sees on the socket.
struct RPCEnvelopeTests {
	private func encode<T: Encodable>(_ value: T) throws -> String {
		String(decoding: try MachmanWire.encoder().encode(value), as: UTF8.self)
	}

	private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
		try MachmanWire.decoder().decode(type, from: Data(json.utf8))
	}

	@Test func requestFixtures() throws {
		let bare = RPCCall<RPCEmpty>(id: .number(1), method: RPCMethod.vmList.rawValue, params: nil)
		#expect(try encode(bare) == #"{"id":1,"jsonrpc":"2.0","method":"vm.list"}"#)

		let withParams = RPCCall(
			id: .number(2), method: RPCMethod.vmGet.rawValue,
			params: RPCParams.Name(name: "Debian"))
		#expect(try encode(withParams)
			== #"{"id":2,"jsonrpc":"2.0","method":"vm.get","params":{"name":"Debian"}}"#)

		let stringID = RPCCall(
			id: .string("a-1"), method: RPCMethod.hello.rawValue,
			params: RPCParams.Hello(client: "smoke"))
		#expect(try encode(stringID)
			== #"{"id":"a-1","jsonrpc":"2.0","method":"machman.hello","params":{"client":"smoke"}}"#)
	}

	@Test func resultAndErrorFixtures() throws {
		let result = RPCResult(
			id: .number(2),
			result: RPCResults.Hello(apiVersion: 1, daemonVersion: "0.2"))
		#expect(try encode(result)
			== #"{"id":2,"jsonrpc":"2.0","result":{"apiVersion":1,"daemonVersion":"0.2"}}"#)

		// The framing, with a fixed message: refusal wording is text, pinned where it is made
		// (VMRefusalTextTests), and must not move these golden bytes.
		let refusal = MachmanError(code: .notFound, message: "no VM named 'x'")
		let error = RPCErrorReply(id: .number(3), error: RPCErrorBody(refusal))
		#expect(try encode(error)
			== #"{"error":{"code":-32000,"data":{"machmanCode":"notFound"},"#
			+ #""message":"no VM named 'x'"},"id":3,"jsonrpc":"2.0"}"#)

		let roundTripped = try decode(RPCErrorReply.self, try encode(error)).error.machmanError
		#expect(roundTripped == refusal)

		// Void results are {}.
		#expect(try encode(RPCResult(id: .number(4), result: RPCEmpty()))
			== #"{"id":4,"jsonrpc":"2.0","result":{}}"#)
	}

	@Test func peekClassifiesLines() throws {
		let request = try decode(RPCPeek.self,
			#"{"id":1,"jsonrpc":"2.0","method":"vm.list"}"#)
		#expect(request.isRequest && !request.isNotification && !request.isResponse)

		let note = try decode(RPCPeek.self,
			#"{"jsonrpc":"2.0","method":"event","params":{"type":"listChanged"}}"#)
		#expect(note.isNotification && !note.isRequest)

		let response = try decode(RPCPeek.self,
			#"{"id":1,"jsonrpc":"2.0","result":{}}"#)
		#expect(response.isResponse && !response.isRequest)
	}
}
