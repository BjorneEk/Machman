//
//  KernelSectionUITests.swift
//  MachmanDesktopUITests
//
//  The device tree's Kernel section and the Kernel inspector while kernel boot is off: a
//  parked section says why it is dimmed (H55). Read only: nothing is pressed.
//

import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: desktop views hosted offscreen, read through in-process accessibility.
@MainActor
struct KernelSectionUITests {
	private static let reason = VMInfo.kernelParkedReason

	private func section(_ h: UIHarness, _ vm: String) async throws -> AXSnapshot {
		try await h.snapshot(
			TreeSectionProbe(harness: h, vm: h.vm(vm)) { AnyView(TreeKernelSection(ctx: $0)) })
	}

	private func kernelInspector(_ h: UIHarness, _ vm: String) async throws -> AXSnapshot {
		try await h.snapshot(
			KernelParentInspector(viewModel: h.viewModel, vm: h.vm(vm)).formStyle(.grouped),
			width: 320, height: 700)
	}

	// H55: the parked groups were only dimmed (opacity 0.45): nothing said they wait for
	// Kernel Boot, to a sighted user or to VoiceOver.
	@Test(
		"H55: a parked Kernel label says it waits for Kernel Boot, to the pointer and to VoiceOver")
	func aParkedLabelSaysWhy() async throws {
		let h = await UIHarness.make([Samples.kernelParked(), Samples.kernelBoot("Booting")])
		let parked = try await section(h, "Kernel Lab")
		for title in ["Kernel", "Initramfs"] {
			let label = parked.findAll { $0.text == title || $0.label == title }
			#expect(label.contains { $0.value == Self.reason }, "\(title): \(parked.dump())")
		}
		#expect(parked.findAll { $0.help == Self.reason }.count >= 2, "\(parked.dump())")

		let booting = try await section(h, "Booting")
		#expect(booting.findAll { $0.value == Self.reason || $0.help == Self.reason }.isEmpty)
	}

	@Test("H55: the parked Kernel inspector opens with the same sentence")
	func theParkedInspectorSaysWhy() async throws {
		let h = await UIHarness.make([Samples.kernelParked(), Samples.kernelBoot("Booting")])
		let parked = try await kernelInspector(h, "Kernel Lab")
		#expect(parked.find(text: Self.reason + ".") != nil, "\(parked.dump())")
		let booting = try await kernelInspector(h, "Booting")
		#expect(booting.find(text: Self.reason + ".") == nil)
	}
}
