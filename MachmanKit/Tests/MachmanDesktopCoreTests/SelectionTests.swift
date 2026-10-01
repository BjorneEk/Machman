import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Tree selection ↔ VM selection ↔ canvas tabs.
@MainActor
struct SelectionTests {
	@Test func launchSelectsTheFirstVM() async {
		let h = await DesktopHarness.make()
		#expect(h.viewModel.selectedName == "Alpine")   // the stub lists by name
	}

	@Test func switchingVMsClearsTheTreeSelection() async {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.viewModel.treeSelection = [.disk("storage:system")]
		h.viewModel.select(name: "Sequoia")
		#expect(h.viewModel.treeSelection.isEmpty)
	}

	// T8: the canvas → tree direction. Tab switches never touched the tree selection, so
	// the inspector stayed on whatever row was clicked last.
	@Test func cyclingTabsSelectsTheTabsRow() async {
		let h = await DesktopHarness.make()
		let console = SerialPortRef(kind: .console, index: 0)
		h.viewModel.select(name: "Debian")
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		h.viewModel.treeSelection = []
		h.viewModel.cycleTab(forward: true)
		#expect(h.viewModel.treeSelection == [.vmRoot])
		h.viewModel.cycleTab(forward: true)
		#expect(h.viewModel.treeSelection == [.serial(console)])
	}

	@Test func openingATabSelectsItsRow() async {
		let h = await DesktopHarness.make()
		let console = SerialPortRef(kind: .console, index: 0)
		h.viewModel.select(name: "Debian")
		h.open(.terminal(console), vm: "Debian")
		#expect(h.viewModel.treeSelection == [.serial(console)])
	}

	@Test func closingTheActiveTabSelectsTheNextOnesRow() async {
		let h = await DesktopHarness.make()
		let console = SerialPortRef(kind: .console, index: 0)
		h.viewModel.select(name: "Debian")
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		#expect(h.viewModel.treeSelection == [.serial(console)])
		h.viewModel.closeTab(.terminal(console), vm: "Debian")
		#expect(h.viewModel.treeSelection == [.vmRoot])
	}

	// Writes that keep the active tab (divider drags, reorders) leave a disk row selected.
	@Test func aDiskRowSurvivesCanvasWrites() async {
		let h = await DesktopHarness.make()
		let console = SerialPortRef(kind: .console, index: 0)
		h.viewModel.select(name: "Debian")
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		var canvas = h.canvases.canvas(for: "Debian")
		canvas.split(.terminal(console))
		h.canvases.setCanvas(canvas, for: "Debian")
		h.viewModel.treeSelection = [.disk("storage:system")]
		canvas = h.canvases.canvas(for: "Debian")
		canvas.setFraction(0.3, at: 0)
		h.canvases.setCanvas(canvas, for: "Debian")
		canvas.reorder(.terminal(console), to: 0)
		h.canvases.setCanvas(canvas, for: "Debian")
		h.open(.config, vm: "Alpine")
		#expect(h.viewModel.treeSelection == [.disk("storage:system")])
	}

	@Test func switchingVMsSelectsNoRow() async {
		let h = await DesktopHarness.make()
		let console = SerialPortRef(kind: .console, index: 0)
		h.viewModel.select(name: "Debian")
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		h.viewModel.select(name: "Sequoia")
		h.viewModel.select(name: "Debian")
		#expect(h.viewModel.treeSelection.isEmpty)
	}

	// Showing a VM fills its empty canvas with the configuration tab (VMCanvasView's
	// fallback). That is part of switching VMs, so it selects no row either.
	@Test func showingAVMsConfigurationSelectsNoRow() async {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.open(.config, vm: "Debian")
		#expect(h.viewModel.treeSelection.isEmpty)
	}

	@Test func closingATabDeselectsItsTreeRow() async {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		h.viewModel.select(name: "Debian")
		h.viewModel.treeSelection = [.serial(ref)]
		h.viewModel.tabClosed(.terminal(ref), vm: "Debian")
		#expect(h.viewModel.treeSelection.isEmpty)
	}
}
