//
//  TGAutostartGuardTests.swift
//  MachmanLabTests
//
//  L2 — Start at login's guard (T22: no job is ever loaded here): turning it on beside a VM
//  that already starts at login with the same writable image is refused. The plist the
//  first VM's switch wrote is removed by hand, so the agent never runs launchctl.
//

import Foundation
import Testing
import MachmanAPI

@Suite("Autostart guard", .serialized, .enabled(if: Lab.runs(.l2)))
struct TGAutostartGuardTests {
	@Test("R3W2-26: Start at login is refused beside a login VM sharing a writable image")
	func refusedBesideLoginSharer() async throws {
		try await TG.withAgent { agent in
			let shared = agent.scope.imagesDir + "/shared-image.img"
			try await TG.writeFile(shared, size: 32 << 20)
			let first = try await TGVM.blank("sharer-a", on: agent)
			let second = try await TGVM.blank("sharer-b", on: agent)
			for vm in [first, second] {
				try await agent.api.addDisk(vm: vm.name, .image(path: shared))
			}
			let plist = TGLaunchd.plistPath(agent.scope, first.name)
			defer { try? FileManager.default.removeItem(atPath: plist) }
			let atLogin = StartPolicy(windowed: false, autostart: true)
			try await agent.api.setStartPolicy(vm: first.name, policy: atLogin)
			#expect(FileManager.default.fileExists(atPath: plist))
			let refused = await #expect(throws: MachmanError.self) {
				try await agent.api.setStartPolicy(vm: second.name, policy: atLogin)
			}
			#expect(refused?.code == .invalidState)
			#expect(refused?.message
				== "sharer-a also starts at login with shared-image.img attached \u{2014} turn off "
				+ "Start at login for one of them")
			#expect(!FileManager.default.fileExists(
				atPath: TGLaunchd.plistPath(agent.scope, second.name)))
			#expect(try await second.info().startPolicy?.autostart != true)
			try FileManager.default.removeItem(atPath: plist)
		}
	}
}
