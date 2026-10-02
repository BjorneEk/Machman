//
//  CaptureWarningTests.swift
//  MachmanCoreTests
//
//  F6: a vmhost's preview-capture warnings went out with vm: nil, so the desktop could
//  never say which VM they were about; one carried a raw window id, another ran to about
//  60 words. A vmhost's registry is restricted to its one VM, which names it.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct CaptureWarningTests {
	@Test func aCaptureWarningNamesItsVM() async throws {
		let registry = try VMTestDir.withRedirectedDir { VMRegistry(only: "alpha") }
		let stream = registry.events.stream()
		let collector = Task {
			var logs: [(vm: String?, level: LogLevel, message: String)] = []
			for await event in stream {
				if case .log(let vm, let level, let message) = event {
					logs.append((vm, level, message))
				}
				if logs.count == 2 { break }
			}
			return logs
		}
		registry.presenter.onCaptureFailed?(.noPermission)
		registry.presenter.onCaptureFailed?(.windowNotFound(1234))
		let logs = await collector.value
		#expect(logs.map(\.vm) == ["alpha", "alpha"])
		#expect(logs.allSatisfy { $0.level == .warning })
		#expect(logs[0].message.contains("Machman VM"))
		#expect(!logs[1].message.contains("1234"))
	}
}
