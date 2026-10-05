//
//  TreeClickTests.swift
//  MachmanDesktopCoreTests
//
//  A plain click on a tree row selects it, whether or not it opens anything (T22). The rows
//  that open on click (the VM root, ports, sessions) take the click themselves, so the List
//  never selected them: clicking an open console's row after a disk left the inspector on
//  the disk, and a host-gated port's inspector (which explains the gate) was out of reach.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct TreeClickTests {
	private let console = SerialPortRef(kind: .console, index: 0)
	private let uart = SerialPortRef(kind: .uart, index: 0)
	private let disk = SidebarNode.disk("storage:system")

	private func debian() async -> DesktopHarness {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		return h
	}

	@Test func clickingAnAlreadyActiveOpenPortSelectsIt() async throws {
		let h = await debian()
		let vm = try #require(h.viewModel.selected)
		h.open(.terminal(console), vm: "Debian")
		h.viewModel.treeSelectionChanged([disk])
		#expect(h.viewModel.treeRowClicked(.serial(console), vm: vm) == nil)
		#expect(h.viewModel.treeSelection == [.serial(console)])
		#expect(h.canvases.canvas(for: "Debian").activeTab == .terminal(console))
	}

	@Test func clickingAGatedPortSelectsItAndOpensNothing() async {
		let h = await DesktopHarness.make([Samples.gatedUART()])
		h.viewModel.select(name: "Kernel Lab")
		h.viewModel.treeSelectionChanged([disk])
		#expect(h.viewModel.treeRowClicked(.serial(uart), vm: Samples.gatedUART()) == nil)
		#expect(h.viewModel.treeSelection == [.serial(uart)])
		#expect(!h.canvases.canvas(for: "Kernel Lab").allOpenTabs.contains(.terminal(uart)))
	}

	@Test func clickingTheRootWithItsConfigurationShowingSelectsIt() async throws {
		let h = await debian()
		let vm = try #require(h.viewModel.selected)
		h.open(.config, vm: "Debian")
		h.viewModel.treeSelectionChanged([disk])
		#expect(h.viewModel.treeRowClicked(.vmRoot, vm: vm) == nil)
		#expect(h.viewModel.treeSelection == [.vmRoot])
		#expect(h.canvases.canvas(for: "Debian").activeTab == .config)
	}

	@Test func clickingAnOpenSessionsRowSelectsIt() async throws {
		let h = await debian()
		let vm = try #require(h.viewModel.selected)
		let session = SSHSessionRef(title: "Session 1")
		h.open(.ssh(session), vm: "Debian")
		h.viewModel.treeSelectionChanged([disk])
		#expect(h.viewModel.treeRowClicked(.sshSession(session), vm: vm) == nil)
		#expect(h.viewModel.treeSelection == [.sshSession(session)])
	}

	@Test func clickingATornTabsRowSelectsItAndHandsBackItsWindow() async throws {
		let h = await debian()
		let vm = try #require(h.viewModel.selected)
		let torn = TornTab(vm: "Debian", tab: .terminal(console))
		h.tornTabs.open.insert(torn)
		#expect(h.viewModel.treeRowClicked(.serial(console), vm: vm) == torn)
		#expect(h.viewModel.treeSelection == [.serial(console)])
		#expect(h.canvases.canvas(for: "Debian").allOpenTabs.isEmpty)
	}

	@Test func clickingARowThatOnlySelectsOpensNothing() async throws {
		let h = await debian()
		let vm = try #require(h.viewModel.selected)
		#expect(h.viewModel.treeRowClicked(disk, vm: vm) == nil)
		#expect(h.viewModel.treeSelection == [disk])
		#expect(h.canvases.canvas(for: "Debian").allOpenTabs.isEmpty)
	}
}
