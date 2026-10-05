//
//  LabDevicePolicyTests.swift
//  MachmanCoreTests
//
//  TB5: a test-suite VM starts without what would reach the host — audio input and output
//  (a microphone prompt, sound), the USB keyboard, pointer and trackpad unless the lab opts
//  in, and clipboard sharing unless it opts in. Outside test mode every resolved device
//  attaches, and resolution's own warnings never change.
//

import Testing
import Foundation
import Virtualization
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct LabDevicePolicyTests {
	private static let suite = "com.gustaffranzen.Machman.test-abc1"

	private static func lab(devices: String? = nil) throws -> LabEnvironment {
		try #require(LabEnvironment(
			suiteID: suite, environment: devices.map { ["MACHMAN_LAB_DEVICES": $0] } ?? [:],
			debugBuild: true))
	}

	private static func attach(_ kinds: [DeviceKind]) -> [DeviceKind: GuestDevice] {
		Dictionary(uniqueKeysWithValues: kinds.map { ($0, GuestDevice(kind: $0)) })
	}

	private static let everyKind: [DeviceKind] = [
		.keyboard, .trackpad, .pointer, .graphics, .audioInput, .audioOutput, .network,
		.clipboard, .entropy, .rosetta, .guestSetup,
	]

	// A stopped EFI VM with the implied device set, built as a start would build it.
	private static func build(
		_ name: String, lab: LabEnvironment?, mutate: (VMConfig) -> Void = { _ in }
	) throws -> BuiltVM {
		try VMConfig.createNewVMDirectory(name: name)
		let vm = try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
		mutate(vm)
		return try vm.assembleVZConfiguration(attachSerial: false, lab: lab)
	}

	private static func sharesClipboard(_ built: BuiltVM) -> Bool? {
		let console = built.configuration.consoleDevices.first as? VZVirtioConsoleDeviceConfiguration
		let port = console?.ports[0]
		return (port?.attachment as? VZSpiceAgentPortAttachment)?.sharesClipboard
	}

	@Test("Q18: outside test mode every resolved device attaches (TB5)")
	func outsideTestModeEveryResolvedDeviceAttaches() throws {
		#expect(LabDevicePolicy.current(lab: nil) == nil)
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let lab = LabEnvironment(
				suiteID: suite, environment: ["MACHMAN_LAB_DEVICES": "hid"], debugBuild: true)
			#expect(LabDevicePolicy.current(lab: lab) == nil)
		}
		try VMTestDir.withRedirectedDir {
			let built = try Self.build("plain", lab: nil)
			#expect(built.configuration.audioDevices.count == 2)
			#expect(built.configuration.keyboards.count == 1)
			#expect(built.configuration.pointingDevices.count == 1)
			#expect(Self.sharesClipboard(built) == true)
		}
	}

	@Test("Q18: a test suite drops audio and the USB keyboard, pointer and trackpad (TB5)")
	func aTestSuiteDropsAudioAndHID() throws {
		let policy = try #require(LabDevicePolicy.current(lab: Self.lab()))
		let applied = policy.apply(Self.attach(Self.everyKind))
		#expect(applied.dropped == [.audioInput, .audioOutput, .keyboard, .pointer, .trackpad])
		#expect(Set(applied.kept.keys) == [
			.graphics, .network, .clipboard, .entropy, .rosetta, .guestSetup,
		])
		#expect(LabDevicePolicy.describe(applied.dropped)
			== "audio input, audio output, keyboard, pointer, trackpad")
		try VMTestDir.withRedirectedDir {
			let built = try Self.build("lab", lab: Self.lab())
			#expect(built.configuration.audioDevices.isEmpty)
			#expect(built.configuration.keyboards.isEmpty)
			#expect(built.configuration.pointingDevices.isEmpty)
			#expect(built.configuration.graphicsDevices.count == 1)
			#expect(built.configuration.networkDevices.count == 1)
		}
	}

	@Test("Q18: MACHMAN_LAB_DEVICES=hid keeps the keyboard, pointer and trackpad (TB5)")
	func hidKeepsTheKeyboardPointerAndTrackpad() throws {
		let policy = try #require(LabDevicePolicy.current(lab: Self.lab(devices: "hid")))
		let applied = policy.apply(Self.attach(Self.everyKind))
		#expect(applied.dropped == [.audioInput, .audioOutput])
		#expect(applied.kept[.keyboard] != nil)
		#expect(applied.kept[.pointer] != nil)
		#expect(applied.kept[.trackpad] != nil)
		try VMTestDir.withRedirectedDir {
			let built = try Self.build("hid", lab: Self.lab(devices: "hid"))
			#expect(built.configuration.audioDevices.isEmpty)
			#expect(built.configuration.keyboards.count == 1)
			#expect(built.configuration.pointingDevices.count == 1)
		}
	}

	@Test("Q18: clipboard sharing is off unless the lab opts in (TB5)")
	func clipboardSharingIsOffUnlessTheLabOptsIn() throws {
		#expect(try #require(LabDevicePolicy.current(lab: Self.lab())).sharesClipboard == false)
		#expect(try #require(LabDevicePolicy.current(lab: Self.lab(devices: "hid,clipboard")))
			.sharesClipboard)
		try VMTestDir.withRedirectedDir {
			// The spice port stays (the topology a person's VM has); only sharing is off.
			let off = try Self.build("clip-off", lab: Self.lab())
			#expect(off.configuration.consoleDevices.count == 1)
			#expect(Self.sharesClipboard(off) == false)
			let on = try Self.build("clip-on", lab: Self.lab(devices: "clipboard"))
			#expect(Self.sharesClipboard(on) == true)
			// An opt-in never turns on what the VM's own setting turned off.
			let declined = try Self.build("clip-declined", lab: Self.lab(devices: "clipboard")) {
				$0.devices[$0.devices.firstIndex { $0.deviceKind == .clipboard }!]
					.sharesClipboard = false
			}
			#expect(Self.sharesClipboard(declined) == false)
		}
	}

	@Test("Q18: the lab policy leaves resolvedDevices' warnings alone (TB5)")
	func theLabPolicyLeavesTheWarningsAlone() throws {
		try VMTestDir.withRedirectedDir {
			let addTrackpad: (VMConfig) -> Void = {
				$0.devices.append(GuestDevice(kind: .trackpad))
			}
			let plain = try Self.build("warn-plain", lab: nil, mutate: addTrackpad)
			let lab = try Self.build("warn-lab", lab: Self.lab(), mutate: addTrackpad)
			#expect(plain.warnings.contains { $0.contains("trackpad") })
			#expect(lab.warnings == plain.warnings)
		}
	}
}
