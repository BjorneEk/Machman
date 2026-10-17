//
//  KernelSectionUITests.swift
//  MachmanDesktopUITests
//
//  The device tree's Kernel section and the Kernel inspector while kernel boot is off: a
//  parked section says why it is dimmed (H55), and the parked Kernel label and inspector offer
//  Remove Kernel Settings… (H54, K2). Read only: nothing is pressed.
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

	private func menuTitles(
		_ h: UIHarness, _ vm: String, _ role: KernelRole
	) async throws -> [AXSnapshot] {
		let tree = try await h.snapshot(TreeMenuProbe(harness: h, vm: h.vm(vm)) {
			AnyView($0.kernelGroupMenu(role: role))
		})
		return tree.findAll { $0.role == "AXButton" }
	}

	// H54 (K2): the parked Kernel label's menu offers the one way out; the Initramfs label and a
	// kernel-booting VM's Kernel label don't.
	@Test("H54: only the parked Kernel label's menu offers Remove Kernel Settings…")
	func onlyTheParkedKernelMenuOffersRemove() async throws {
		let h = await UIHarness.make([
			Samples.kernelParked(), Samples.kernelBoot("Booting"),
			Samples.kernelParkedRunning("Running"),
		])
		let remove = "Remove Kernel Settings\u{2026}"
		let parked = try await menuTitles(h, "Kernel Lab", .kernel)
		#expect(parked.compactMap(\.text) == ["Add from Disk\u{2026}", "Paste", remove])
		#expect(parked.last?.isEnabled == true)
		let initramfs = try await menuTitles(h, "Kernel Lab", .initramfs)
		#expect(!initramfs.compactMap(\.text).contains(remove))
		let booting = try await menuTitles(h, "Booting", .kernel)
		#expect(!booting.compactMap(\.text).contains(remove))
		// A running VM's offers it dimmed, with the reason.
		let running = try await menuTitles(h, "Running", .kernel)
		let item = try #require(running.first { $0.text == remove })
		#expect(!item.isEnabled)
		#expect(item.help == "Stop the VM to remove its kernel settings")
	}

	@Test("H54: the parked Kernel inspector ends with Remove Kernel Settings…")
	func theParkedInspectorOffersRemove() async throws {
		let h = await UIHarness.make([
			Samples.kernelParked(), Samples.kernelBoot("Booting"),
			Samples.kernelParkedRunning("Running"),
		])
		let remove = "Remove Kernel Settings\u{2026}"
		let parked = try await kernelInspector(h, "Kernel Lab")
		let button = try #require(parked.find(role: "AXButton", text: remove), "\(parked.dump())")
		#expect(button.isEnabled)
		#expect(button.help == "Deletes the VM’s kernel files and clears its kernel settings")
		let booting = try await kernelInspector(h, "Booting")
		#expect(booting.find(role: "AXButton", text: remove) == nil)
		let running = try await kernelInspector(h, "Running")
		let dimmed = try #require(running.find(role: "AXButton", text: remove))
		#expect(!dimmed.isEnabled)
		#expect(dimmed.help == "Stop the VM to remove its kernel settings")
	}

	// D31 (removal only): a macOS VM never boots a kernel, so the kernel files kept from before
	// its switch offer only what removes them — no adds, paste, picks, re-tags or promotes.
	@Test("D31: a macOS VM's kernel menus and inspectors offer removal only")
	func aMacOSVMOffersRemovalOnly() async throws {
		let h = await UIHarness.make([Samples.macOSWithKernelFiles()])
		let mac = h.vm("Sequoia")
		let kernel = try await menuTitles(h, "Sequoia", .kernel)
		#expect(kernel.compactMap(\.text) == ["Remove Kernel Settings\u{2026}"])
		let initramfs = try await menuTitles(h, "Sequoia", .initramfs)
		#expect(initramfs.isEmpty)
		let file = try #require(mac.kernelTreeEntries(role: .kernel).first)
		let entry = try await h.snapshot(TreeMenuProbe(harness: h, vm: mac) {
			AnyView($0.kernelEntryMenu(file, role: .kernel))
		})
		#expect(entry.findAll { $0.role == "AXButton" }.compactMap(\.text)
			== ["Copy", "Show in Finder", "Delete\u{2026}"])
		let inspector = try await h.snapshot(
			KernelEntryInspector(viewModel: h.viewModel, vm: mac, path: file.id)
				.formStyle(.grouped),
			width: 320, height: 700)
		for gone in ["Select", "Deselect"] {
			#expect(inspector.find(role: "AXButton", text: gone) == nil, "\(inspector.dump())")
		}
		#expect(inspector.findAll { $0.role == "AXTextField" }.isEmpty)
	}
}
