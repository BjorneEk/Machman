//
//  MenuBarModelTests.swift
//  MachmanUITests
//
//  V9: the agent's menu model listed the VMs as soon as the app was created, whether or not
//  that agent ever won the socket. A list adopts every live vmhost it meets, so an agent that
//  stepped aside for another took that agent's VMs over and then offered to stop them when it
//  quit. The model now lists only once begun, which only a serving agent does.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
import MachmanUI

@MainActor
struct MenuBarModelTests {
	@Test func aModelThatNeverBeganAsksNothing() async {
		let stub = StubMachman()
		stub.vms["Debian"] = Samples.linux("Debian", state: .running)
		let idle = MenuBarModel(api: stub)
		let serving = MenuBarModel(api: stub)
		serving.begin()
		// Both models' work runs on the main actor in the order it started: once the serving
		// one has listed, an idle model that asked anything has asked it too.
		#expect(await eventually { !serving.vms.isEmpty })
		#expect(stub.calls == ["events", "listVMs"])
		#expect(idle.vms.map(\.name) == [])
	}

	@Test func beginIsIdempotentAndFollowsTheList() async {
		let stub = StubMachman()
		stub.vms["Debian"] = Samples.linux("Debian", state: .running)
		let model = MenuBarModel(api: stub)
		model.begin()
		model.begin()
		#expect(await eventually { model.vms.map(\.name) == ["Debian"] })
		stub.vms["Alpine"] = Samples.linux("Alpine")
		stub.emit(.listChanged)
		#expect(await eventually { model.vms.map(\.name) == ["Alpine", "Debian"] })
		#expect(stub.calls.filter { $0 == "events" }.count == 1)
	}
}
