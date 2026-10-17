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

	// TB12: the lab's `menu <action> <vm>` runs an agent menu item only where the menu would
	// enable it, through the same calls the menu makes.
	@Test("Q18: a lab menu command acts only where the agent menu's item is enabled (TB12)")
	func aLabMenuCommandActsOnlyWhereTheItemIsEnabled() async {
		let stub = StubMachman()
		stub.vms["Debian"] = Samples.linux("Debian")
		stub.vms["Sequoia"] = Samples.macOS("Sequoia")
		var stuck = Samples.linux("Stuck", state: .running)
		stuck.unresponsive = true
		stub.vms["Stuck"] = stuck
		var blind = Samples.linux("Blind", state: .running)
		blind.devices = blind.devices?.filter { $0.kind != .graphics }
		stub.vms["Blind"] = blind
		let model = MenuBarModel(api: stub)
		var asked: [EndProcessPrompt] = []
		model.confirmEndProcess = { prompt in
			asked.append(prompt)
			return false
		}
		model.begin()
		#expect(await eventually { model.vms.count == 4 })

		// A live macOS install: Start waits, as the menu's item does.
		stub.emit(.installPhaseChanged(vm: "Sequoia", phase: InstallPhase(kind: .installing)))
		let sequoia = model.vms.first { $0.name == "Sequoia" }!
		#expect(await eventually { !model.canStart(sequoia) })
		#expect(model.performLab(.start, vm: "Sequoia") == .disabled)
		#expect(!stub.calls.contains("start"))

		#expect(model.performLab(.startHeadless, vm: "Debian") == .done)
		#expect(await eventually { stub.starts.count == 1 })
		#expect(stub.starts.first?.vm == "Debian")
		#expect(stub.starts.first?.options == Samples.linux("Debian").startOptions(.headless))

		// Force Stop on a VM that isn't answering asks about its process first.
		#expect(model.performLab(.forceStop, vm: "Stuck") == .done)
		#expect(await eventually { asked == [.forVM("Stuck")] })
		#expect(!stub.calls.contains("stop"))

		// No display: the menu has no window item, so there is nothing to open.
		#expect(model.performLab(.openWindow, vm: "Blind") == .disabled)
		#expect(model.performLab(.closeWindow, vm: "Blind") == .disabled)
		#expect(model.performLab(.start, vm: "Nobody") == .noSuchVM)
		#expect(stub.windowOpens == 0)
	}

	@Test("Q18: the lab path and the agent menu share one enablement rule (TB12)")
	func theLabPathAndTheMenuShareOneRule() {
		let model = MenuBarModel(api: StubMachman())
		var open = Samples.linux("Open", state: .running)
		open.windowOpen = false
		let samples = [
			Samples.linux("Stopped"), Samples.linux("Running", state: .running), open,
			Samples.macOS("Mac"), Samples.macOS("MacRunning", state: .running),
			Samples.linux("Unknown", state: .unknown),
		]
		for vm in samples {
			for action in [LabMenuAction.start, .startHeadless, .startSafe] {
				#expect(model.isEnabled(action, vm) == model.canStart(vm), "\(vm.name) \(action)")
			}
			for action in [LabMenuAction.shutDown, .forceStop] {
				#expect(model.isEnabled(action, vm) == vm.menuBarCanStop, "\(vm.name) \(action)")
			}
			#expect(model.isEnabled(.openWindow, vm) == (vm.windowAction == .open), "\(vm.name)")
			#expect(model.isEnabled(.closeWindow, vm) == (vm.windowAction == .close), "\(vm.name)")
		}
		// The table covers both sides of every rule.
		#expect(samples.contains { model.isEnabled(.start, $0) })
		#expect(samples.contains { !model.isEnabled(.start, $0) })
		#expect(samples.contains { model.isEnabled(.openWindow, $0) })
		#expect(samples.contains { model.isEnabled(.closeWindow, $0) })
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

	@Test("H65: Show VMs in Finder opens the library folder")
	func showVMsInFinderOpensTheLibrary() {
		let model = MenuBarModel(api: StubMachman())
		var opened: [String] = []
		model.openFolder = { opened.append($0) }
		model.showVMsInFinder()
		#expect(opened == [MachmanPaths.vmsDir()])   // the VMs, not the data dir holding them
	}

	@Test("V16: a burst of listChanged costs at most two more lists")
	func aBurstOfListChangesIsCoalesced() async throws {
		let stub = StubMachman()
		stub.vms["Debian"] = Samples.linux("Debian")
		let model = MenuBarModel(api: stub)
		model.begin()
		#expect(await eventually { model.vms.count == 1 })
		var release: CheckedContinuation<Void, Never>?
		stub.pause = { name in
			guard name == "listVMs" else { return }
			await withCheckedContinuation { release = $0 }
		}
		for _ in 0..<5 { stub.emit(.listChanged) }
		// Events are read in order: once this one shows on the row, the menu has read the whole
		// burst while the first list was still out.
		stub.emit(.stateChanged(vm: "Debian", state: .starting))
		#expect(await eventually { release != nil && model.vms.first?.state == .starting })
		stub.pause = nil
		stub.vms["Alpine"] = Samples.linux("Alpine")
		release?.resume()
		#expect(await eventually { model.vms.map(\.name) == ["Alpine", "Debian"] })
		try await Task.sleep(for: .milliseconds(100))
		// The first list, the one the burst found in flight, and one after it.
		#expect(stub.calls.filter { $0 == "listVMs" }.count <= 3, "\(stub.calls)")
	}

	@Test("V16: a state change during a list stays over that list")
	func aStateChangeDuringAListStays() async throws {
		let stub = StubMachman()
		stub.vms["Debian"] = Samples.linux("Debian")
		let model = MenuBarModel(api: stub)
		model.begin()
		#expect(await eventually { model.vms.count == 1 })
		var release: CheckedContinuation<Void, Never>?
		stub.pause = { name in
			guard name == "listVMs" else { return }
			await withCheckedContinuation { release = $0 }
		}
		stub.emit(.listChanged)
		#expect(await eventually { release != nil })   // that list carries Debian stopped
		stub.pause = nil
		stub.vms["Debian"]?.state = .running
		stub.emit(.stateChanged(vm: "Debian", state: .running))
		// The menu patches the row at once, not after the list in flight.
		#expect(await eventually { model.vms.first?.state == .running })
		release?.resume()
		try await Task.sleep(for: .milliseconds(100))
		#expect(model.vms.first?.state == .running)
	}
}
