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

	// C9 (E36): Force Stop on a VM listed as not responding asks a second time, and only a
	// yes ends its process; the stop itself is never sent to a host that won't answer.
	@Test func aForceStopOfANotRespondingVMAsksFirst() async {
		let stub = StubMachman()
		var debian = Samples.linux("Debian", state: .running)
		debian.unresponsive = true
		stub.vms["Debian"] = debian
		let model = MenuBarModel(api: stub)
		var asked: [EndProcessPrompt] = []
		var answer = false
		model.confirmEndProcess = { prompt in
			asked.append(prompt)
			return answer
		}
		model.begin()
		#expect(await eventually { !model.vms.isEmpty })

		model.stop("Debian", mode: .force)
		#expect(await eventually { asked == [.forVM("Debian")] })
		#expect(!stub.calls.contains("endProcess"))   // "Cancel"

		answer = true
		model.stop("Debian", mode: .force)
		#expect(await eventually { stub.calls.contains("endProcess") })
		#expect(!stub.calls.contains("stop"))
	}

	// A host that wedged after the list last said so: the bounded stop's timeout asks too.
	@Test func aTimedOutForceStopAsksAboutTheProcess() async {
		let stub = StubMachman()
		stub.vms["Debian"] = Samples.linux("Debian", state: .running)
		stub.fail("stop", with: MachmanError(
			code: .timeout, message: "Debian isn\u{2019}t answering, so it didn\u{2019}t stop"))
		let model = MenuBarModel(api: stub)
		model.confirmEndProcess = { _ in true }
		model.begin()
		#expect(await eventually { !model.vms.isEmpty })

		model.stop("Debian", mode: .force)
		#expect(await eventually { stub.calls.contains("endProcess") })
	}
}
