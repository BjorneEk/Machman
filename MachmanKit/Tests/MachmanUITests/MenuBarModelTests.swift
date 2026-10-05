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

	// Review F12: an engine from before vm.process.end gets the force stop it knows.
	@Test func anOlderEngineGetsAForceStopInstead() async {
		let stub = StubMachman()
		var debian = Samples.linux("Debian", state: .running)
		debian.unresponsive = true
		stub.vms["Debian"] = debian
		stub.fail("endProcess", with: MachmanError(
			code: .unsupported, message: "unknown method 'vm.process.end'"))
		let model = MenuBarModel(api: stub)
		model.confirmEndProcess = { _ in true }
		model.begin()
		#expect(await eventually { !model.vms.isEmpty })

		model.stop("Debian", mode: .force)
		#expect(await eventually { stub.calls.suffix(2) == ["endProcess", "stop"] })
	}

	// TB9: the failure alert is a seam now, so a test (and the lab, through it) sees what the
	// menu would say; Start Anyway is the same start, forced.
	@Test("Q18: a failed menu start is presented through presentFailure (TB9)")
	func aFailedMenuStartIsPresentedThroughTheSeam() async {
		let stub = StubMachman()
		stub.vms["Debian"] = Samples.linux("Debian")
		stub.fail("start", with: MachmanError(
			code: .macConflict, message: "Alpine already uses 5e:2c:7a:10:44:01"))
		let model = MenuBarModel(api: stub)
		var presented: [MenuBarFailure] = []
		model.presentFailure = { failure in
			presented.append(failure)
			return true
		}
		model.begin()
		#expect(await eventually { !model.vms.isEmpty })
		let vm = model.vms[0]

		model.start(vm, .headless)
		// The refused start is called (and fails), then the forced one starts it.
		#expect(await eventually { stub.calls.filter { $0 == "start" }.count == 2 })
		#expect(presented.map(\.title) == ["MAC address conflict"])
		#expect(presented.first?.labPrompt.id == "agent.macConflict")
		#expect(stub.starts.map(\.options) == [
			StartOptions(openWindow: false, force: true, safe: vm.startOptions(.headless).safe),
		])
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
