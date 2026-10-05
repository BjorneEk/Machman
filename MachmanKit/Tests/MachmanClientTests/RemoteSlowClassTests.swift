//
//  RemoteSlowClassTests.swift
//  MachmanClientTests
//
//  E40: kernel.promote copies a kernel or initramfs (tens of MiB, from any volume) and was on
//  the 30 s default, so a slow copy reported failure while it completed. The calls that run
//  long are one list now, kernel.promote among them.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
import MachmanClient

struct RemoteSlowClassTests {
	@Test func everyByteCopyIsSlowClass() {
		#expect(RemoteMachman.slowMethods == [
			.vmCopy, .diskImport, .diskPromote, .kernelPromote, .safeSave, .start,
			.installRosetta,
		])
		#expect(RemoteMachman.deadline(for: .kernelPromote) == RPCConnection.slowCallDeadline)
		#expect(RemoteMachman.deadline(for: .vmGet) == RPCConnection.defaultCallDeadline)
	}
}
