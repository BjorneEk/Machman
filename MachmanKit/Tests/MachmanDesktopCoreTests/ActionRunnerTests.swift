//
//  ActionRunnerTests.swift
//  MachmanDesktopCoreTests
//
//  Every request the desktop sends the daemon, pinned by what it says (Q1): a refusal is an
//  alert titled by the action that failed with the error's own sentence, or the reason under
//  the field that asked; a success shows its toast or nothing; and the flags, refreshes and
//  selection moves around a call keep their order. Written before the actions moved onto one
//  runner, so the runner proves it changed none of it.
//

import Testing
import Foundation
import Combine
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct ActionRunnerTests {
	private static let refusal = MachmanError(code: .ioFailure, message: "no can do")
	private static let mount = "7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11"
	private static let iso = "iso:file:///Users/demo/Downloads/debian-13-arm64-netinst.iso"
	private static let kernel = "\(Samples.vmsRoot)/Kernel Lab/kernels/kernel/6.12/vmlinuz"

	// One action, the stub method it reaches and what it says: an alert title or a toast.
	struct Case {
		let method: String
		let says: String
		let vms: [VMInfo]
		let run: @MainActor (VMListViewModel) -> Void

		init(
			_ method: String, _ says: String, vms: [VMInfo] = Samples.library(),
			_ run: @escaping @MainActor (VMListViewModel) -> Void
		) {
			self.method = method
			self.says = says
			self.vms = vms
			self.run = run
		}
	}

	private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }

	private static func pendingApproval() -> [VMInfo] {
		var vm = Samples.linux("Alpine")
		vm.ssh?.reverseState = .pending
		return [vm]
	}

	// MARK: - Refusals

	static var refused: [Case] {
		let q = quoted
		return [
			Case("start", "Starting \(q("Alpine")) failed") { $0.startVM("Alpine") },
			Case("openWindow", "Opening the \(q("Debian")) window failed") {
				$0.openWindow("Debian")
			},
			Case("closeWindow", "Closing the \(q("Debian")) window failed") {
				$0.closeWindow("Debian")
			},
			Case("stop", "Shutting down \(q("Debian")) failed") {
				$0.stopVM("Debian", mode: .soft)
			},
			Case("stop", "Force stopping \(q("Debian")) failed") {
				$0.stopVM("Debian", mode: .force)
			},
			Case("endProcess", "Ending the process of \(q("Debian")) failed") {
				$0.endProcess("Debian")
			},
			Case("createVM", "Creating a VM failed") { vm in Task { _ = await vm.createVM() } },
			Case("deleteVM", "Deleting \(q("Alpine")) failed") {
				$0.performDeleteVM(Samples.linux("Alpine"))
			},
			Case("renameVM", "Renaming \(q("Alpine")) failed") { vm in
				Task { _ = await vm.rename(from: "Alpine", to: "Alpine 2") }
			},
			Case("setHardware", "Updating hardware for \(q("Alpine")) failed") {
				$0.setHardware("Alpine", cpuCount: 2)
			},
			Case("copyVM", "Duplicating \(q("Alpine")) failed") {
				$0.copyVM("Alpine", newName: "Alpine 2", diskIDs: [])
			},
			Case("importDisk", "Importing \(q("extra.raw")) into \(q("Alpine")) failed") {
				$0.importDisks("Alpine", paths: ["/Users/demo/extra.raw"])
			},
			Case("importDisk", "Importing a disk into \(q("Alpine")) failed") {
				$0.importDisk("Alpine", path: "/Users/demo/extra.raw")
			},
			Case("promoteDisk", "Promoting a disk on \(q("Alpine")) failed") {
				$0.promoteDisk("Alpine", diskID: iso)
			},
			Case("renameDisk", "Renaming a disk failed") {
				$0.renameDisk("Alpine", diskID: "storage:system", newName: "data")
			},
			Case("setMountTag", "Changing a mount tag failed") {
				$0.setMountTag("Alpine", mountID: mount, tag: "code")
			},
			Case("setMountKind", "Changing a mount’s kind failed") {
				$0.setMountKind("Alpine", mountID: mount, kind: MountKind.virtiofs)
			},
			Case("renameKernelFile", "Renaming a kernel file failed") {
				$0.renameKernelTag("Kernel Lab", path: kernel, tag: "6.13")
			},
			Case("resizeDisk", "Growing a disk failed") {
				$0.resizeDisk("Alpine", diskID: "storage:system", sizeBytes: 64 << 30)
			},
			Case("setSafety", "Updating disk safety failed") {
				$0.setDiskSafety("Alpine", diskID: "storage:system", safe: true)
			},
			Case("setSafety", "Updating mount safety failed") {
				$0.setMountSafety("Alpine", mountID: mount, safe: true)
			},
			Case(
				"safeSave", "Saving \(q("Debian")) as a new VM failed",
				vms: [Samples.linuxSafeRun("Debian")]
			) { $0.safeSave("Debian", to: "Debian kept") },
			Case("setStartPolicy", "Updating the default start for \(q("Alpine")) failed") {
				$0.setStartPolicy("Alpine", policy: StartPolicy())
			},
			Case("regenerateMAC", "Regenerating the MAC address failed") {
				$0.regenerateMAC("Alpine")
			},
			Case("installRosetta", "Installing Rosetta failed") { $0.installRosetta() },
			Case("addDisk", "Adding a disk failed") {
				$0.addDisk("Alpine", .storage(name: "data", sizeBytes: 8 << 30))
			},
			Case("addDisk", "Adding \(q("extra.img")) failed") {
				$0.addDisks("Alpine", [.image(path: "/Users/demo/extra.img")])
			},
			Case("removeDisk", "Removing a disk failed") {
				$0.removeDisk("Alpine", diskID: "storage:system")
			},
			Case("addMount", "Adding a mount failed") {
				$0.addMount("Alpine", path: "/Users/demo/data", tag: "data")
			},
			Case("removeMount", "Removing a mount failed") {
				$0.removeMount("Alpine", mountID: mount)
			},
			Case("addDevice", "Adding a device failed") { $0.addDevice("Alpine", kind: .entropy) },
			Case("removeDevice", "Removing a device failed") {
				$0.removeDevice("Alpine", kind: .keyboard)
			},
			Case("updateDevice", "Updating a device failed") {
				$0.updateDevice("Alpine", device: DeviceInfo(kind: .keyboard))
			},
			Case("setSSH", "Adding \(q("alpine.machman")) to your SSH config failed") {
				$0.setSSHIntegration("Alpine", enabled: true)
			},
			Case("setSSH", "Renaming the SSH alias failed") {
				$0.setSSHAlias("Alpine", alias: "box")
			},
			Case("setSSH", "Updating guest access failed") {
				$0.setSSHReverseApproved("Alpine", approved: true)
			},
			Case("refreshSSH", "Looking for the address of \(q("Debian")) failed") {
				$0.refreshSSH("Debian")
			},
			Case("resetSSH", "Resetting SSH state failed") { $0.resetSSH("Alpine") },
			Case("resetSetup", "Resetting guest setup state failed") { $0.resetSetup("Alpine") },
			Case("setSetupServed", "Changing the reinstall setting failed") {
				$0.setSetupServed("Alpine", serve: true)
			},
			Case("setEnabled", "Updating enabled state failed") {
				$0.setEnabled("Alpine", disks: ["storage:system": false])
			},
			Case("addConsolePort", "Adding a console port failed") {
				$0.addConsolePort("Alpine")
			},
			Case("removeConsolePort", "Removing a console port failed") {
				$0.removeConsolePort("Alpine")
			},
			Case("addUartPort", "Adding a UART port failed") { $0.addUartPort("Alpine") },
			Case("removeUartPort", "Removing a UART port failed") {
				$0.removeUartPort("Kernel Lab")
			},
			Case("promoteKernelFile", "Promoting a kernel file failed") {
				$0.promoteKernel(
					"Kernel Lab", role: .kernel, sourcePath: "/Users/demo/vmlinuz", tag: "6.13")
			},
			Case("deleteKernelFile", "Deleting a kernel file failed") {
				$0.deleteKernel("Kernel Lab", path: kernel)
			},
			Case("setSerialLogging", "Updating serial logging failed") {
				$0.setSerialLogging(
					"Alpine", kind: .console, index: 0, config: SerialLogConfig())
			},
			Case("setKernelBoot", "Switching boot mode failed") { vm in
				Task { _ = await vm.setKernelBoot("Kernel Lab", enabled: false) }
			},
			Case("setKernelOverride", "Updating the kernel override failed") {
				$0.setKernelOverride("Kernel Lab", path: kernel, commandLine: "quiet")
			},
			Case("updateKernelSettings", "Saving kernel settings failed") {
				$0.setActiveKernelFile(Samples.kernelBoot(), role: .initramfs, path: nil)
			},
			Case("startMacInstall", "Starting the macOS install failed") {
				$0.startInstall("Sequoia", source: .latest)
			},
			Case("cancelMacInstall", "Canceling the macOS install failed") {
				$0.cancelInstall("Sequoia")
			},
			Case("cancelOperation", "Canceling the operation failed") {
				$0.cancelOperation(id: "op-1")
			},
		]
	}

	@Test func everyRefusedActionSaysWhatFailed() async {
		for c in Self.refused {
			let h = await DesktopHarness.make(c.vms)
			h.stub.fail(c.method, with: Self.refusal)
			c.run(h.viewModel)
			#expect(await eventually { h.viewModel.presentedError != nil }, "\(c.says)")
			#expect(h.viewModel.presentedError?.title == c.says)
			#expect(h.viewModel.presentedError?.message == "no can do", "\(c.says)")
			#expect(h.stub.calls.contains(c.method), "\(c.says)")
		}
	}

	// The inspector's fields take a refusal under themselves; nothing alerts.
	@Test func aFieldThatAskedHearsTheRefusal() async {
		let fields: [(String, @MainActor (VMListViewModel, @escaping (String) -> Void) -> Void)] = [
			("renameDisk", {
				$0.renameDisk("Alpine", diskID: "storage:system", newName: "data", refused: $1)
			}),
			("setMountTag", {
				$0.setMountTag("Alpine", mountID: Self.mount, tag: "code", refused: $1)
			}),
			("renameKernelFile", {
				$0.renameKernelTag("Kernel Lab", path: Self.kernel, tag: "6.13", refused: $1)
			}),
			("renameVM", { vm, refused in
				Task { _ = await vm.rename(from: "Alpine", to: "Alpine 2", refused: refused) }
			}),
		]
		for (method, run) in fields {
			let h = await DesktopHarness.make()
			h.stub.fail(method, with: Self.refusal)
			var heard: String?
			run(h.viewModel) { heard = $0 }
			#expect(await eventually { heard != nil }, "\(method)")
			#expect(heard == "no can do", "\(method)")
			#expect(h.viewModel.presentedError == nil, "\(method)")
		}
	}

	// MARK: - Successes

	static var toasting: [Case] {
		let q = quoted
		return [
			Case("regenerateMAC", "MAC address regenerated") { $0.regenerateMAC("Alpine") },
			Case("addDisk", "Added disk") {
				$0.addDisk("Alpine", .storage(name: "data", sizeBytes: 8 << 30))
			},
			Case("addDisk", "Added disk") {
				$0.addDisks("Alpine", [.image(path: "/Users/demo/a.img")])
			},
			Case("addDisk", "Added 2 disks") {
				$0.addDisks(
					"Alpine",
					[.image(path: "/Users/demo/a.img"), .iso(path: "/Users/demo/b.iso")])
			},
			Case("removeDisk", "Removed disk") {
				$0.removeDisk("Alpine", diskID: "storage:system")
			},
			Case("addMount", "Added mount \(q("data"))") {
				$0.addMount("Alpine", path: "/Users/demo/data", tag: "data")
			},
			Case("removeMount", "Removed mount") { $0.removeMount("Alpine", mountID: mount) },
			Case("addDevice", "Added entropy") { $0.addDevice("Alpine", kind: .entropy) },
			Case("removeDevice", "Removed keyboard") {
				$0.removeDevice("Alpine", kind: .keyboard)
			},
			Case("setSSH", "Approved Alpine’s access to this Mac") {
				$0.setSSHReverseApproved("Alpine", approved: true)
			},
			Case("setSSH", "Revoked Alpine’s access to this Mac") {
				$0.setSSHReverseApproved("Alpine", approved: false)
			},
			Case("setSSH", "Denied Alpine’s access to this Mac", vms: pendingApproval()) {
				$0.setSSHReverseApproved("Alpine", approved: false)
			},
			Case("resetSSH", "SSH state reset for Alpine") { $0.resetSSH("Alpine") },
			Case("resetSetup", "Guest setup state reset for Alpine") { $0.resetSetup("Alpine") },
			Case("addConsolePort", "Added console port") { $0.addConsolePort("Alpine") },
			Case("removeConsolePort", "Removed console port") { $0.removeConsolePort("Alpine") },
			Case("addUartPort", "Added UART port") { $0.addUartPort("Alpine") },
			Case("removeUartPort", "Removed UART port") { $0.removeUartPort("Kernel Lab") },
			Case("resizeDisk", "Disk grown to 64 GB") {
				$0.resizeDisk("Alpine", diskID: "storage:system", sizeBytes: 64 << 30)
			},
			Case("setMountTag", "Renamed to \(q("code"))") {
				$0.setMountTag("Alpine", mountID: mount, tag: "code")
			},
			Case("renameDisk", "Renamed to \(q("data"))") {
				$0.renameDisk("Alpine", diskID: "storage:system", newName: "data")
			},
		]
	}

	@Test func everySuccessToastsWhatItDid() async {
		for c in Self.toasting {
			let h = await DesktopHarness.make(c.vms)
			c.run(h.viewModel)
			#expect(
				await eventually { h.viewModel.toasts.contains { $0.message == c.says } },
				"\(c.method): no \(c.says)")
			#expect(h.viewModel.presentedError == nil, "\(c.says)")
		}
	}

	// Settings changes and window orders say nothing on success; the list shows the result.
	static var quiet: [Case] {
		[
			Case("openWindow", "") { $0.openWindow("Debian") },
			Case("closeWindow", "") { $0.closeWindow("Debian") },
			Case("setHardware", "") { $0.setHardware("Alpine", cpuCount: 2) },
			Case("importDisk", "") { $0.importDisk("Alpine", path: "/Users/demo/extra.raw") },
			Case("importDisk", "") { $0.importDisks("Alpine", paths: ["/Users/demo/extra.raw"]) },
			Case("promoteDisk", "") { $0.promoteDisk("Alpine", diskID: iso) },
			Case("setMountKind", "") {
				$0.setMountKind("Alpine", mountID: mount, kind: MountKind.virtiofs)
			},
			Case("setSafety", "") {
				$0.setDiskSafety("Alpine", diskID: "storage:system", safe: true)
			},
			Case("setSafety", "") { $0.setMountSafety("Alpine", mountID: mount, safe: true) },
			Case("setStartPolicy", "") { $0.setStartPolicy("Alpine", policy: StartPolicy()) },
			Case("updateDevice", "") {
				$0.updateDevice("Alpine", device: DeviceInfo(kind: .keyboard))
			},
			Case("setSSH", "") { $0.setSSHIntegration("Alpine", enabled: false) },
			Case("setSSH", "") { $0.setSSHAlias("Alpine", alias: "box") },
			Case("setSetupServed", "") { $0.setSetupServed("Alpine", serve: true) },
			Case("setEnabled", "") { $0.setEnabled("Alpine", disks: ["storage:system": false]) },
			Case("promoteKernelFile", "") {
				$0.promoteKernel(
					"Kernel Lab", role: .kernel, sourcePath: "/Users/demo/vmlinuz", tag: "6.13")
			},
			Case("deleteKernelFile", "") { $0.deleteKernel("Kernel Lab", path: kernel) },
			// The reply doesn't hold a file under the new tag (the stub keeps the old one), so
			// there is nothing to say it was renamed to.
			Case("renameKernelFile", "") {
				$0.renameKernelTag("Kernel Lab", path: kernel, tag: "6.13")
			},
			Case("setSerialLogging", "") {
				$0.setSerialLogging(
					"Alpine", kind: .console, index: 0, config: SerialLogConfig())
			},
			Case("setKernelBoot", "") { vm in
				Task { _ = await vm.setKernelBoot("Kernel Lab", enabled: false) }
			},
			Case("setKernelOverride", "") {
				$0.setKernelOverride("Kernel Lab", path: kernel, commandLine: "quiet")
			},
			Case("updateKernelSettings", "") {
				$0.setActiveKernelFile(Samples.kernelBoot(), role: .initramfs, path: nil)
			},
			Case("startMacInstall", "") { $0.startInstall("Sequoia", source: .latest) },
			Case("cancelMacInstall", "") { $0.cancelInstall("Sequoia") },
		]
	}

	@Test func quietActionsSayNothing() async throws {
		for c in Self.quiet {
			let h = await DesktopHarness.make(c.vms)
			c.run(h.viewModel)
			#expect(await eventually { h.stub.calls.contains(c.method) }, "\(c.method)")
			try await Task.sleep(for: .milliseconds(100))
			#expect(h.viewModel.toasts.isEmpty, "\(c.method): \(h.viewModel.toasts.map(\.message))")
			#expect(h.viewModel.presentedError == nil, "\(c.method)")
		}
	}

	// MARK: - Around the call

	// The pending flag outlives the start until a fresh list has landed, so the affordances
	// flip straight from pending to the running controls.
	@Test func aStartStaysPendingUntilTheFreshList() async {
		let h = await DesktopHarness.make()
		var listedFirst: Bool?
		let watch = h.viewModel.$pendingStarts.sink { incoming in
			guard !incoming.contains("Alpine"), let start = h.stub.calls.lastIndex(of: "start")
			else { return }
			listedFirst = h.stub.calls[start...].contains("listVMs")
		}
		h.viewModel.startVM("Alpine")
		#expect(h.viewModel.isStartPending("Alpine"))
		#expect(await eventually { !h.viewModel.isStartPending("Alpine") })
		#expect(listedFirst == true)
		watch.cancel()
	}

	@Test func aFailedStartIsNoLongerPending() async {
		let h = await DesktopHarness.make()
		h.stub.fail("start", with: Self.refusal)
		h.viewModel.startVM("Alpine")
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(!h.viewModel.isStartPending("Alpine"))
	}

	@Test func aCopySelectsTheNewVM() async {
		let h = await DesktopHarness.make()
		h.viewModel.copyVM("Alpine", newName: "Alpine 2", diskIDs: [])
		#expect(h.viewModel.copyInFlight)
		#expect(await eventually { h.viewModel.selectedName == "Alpine 2" })
		#expect(h.viewModel.selected?.name == "Alpine 2")
		#expect(!h.viewModel.copyInFlight)
	}

	@Test func aFailedCopyLetsTheNextOneGo() async {
		let h = await DesktopHarness.make()
		h.stub.fail("copyVM", with: Self.refusal)
		h.viewModel.copyVM("Alpine", newName: "Alpine 2", diskIDs: [])
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(!h.viewModel.copyInFlight)
		#expect(h.viewModel.selectedName == "Alpine")
	}

	@Test func aFailedSafeSaveClosesTheSheet() async {
		let debian = Samples.linuxSafeRun("Debian")
		let h = await DesktopHarness.make([debian])
		h.viewModel.requestSafeSave(debian)
		h.stub.fail("safeSave", with: Self.refusal)
		h.viewModel.safeSave("Debian", to: "Debian kept")
		#expect(h.viewModel.safeSaveInFlight)
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(h.viewModel.safeSaveRequest == nil)
		#expect(!h.viewModel.safeSaveInFlight)
	}

	// The picker can delete a VM that isn't the shown one: the selection stays unless it was
	// the one deleted, which falls over to the first VM once the list lands.
	@Test func deletingAnotherVMKeepsTheSelection() async {
		let h = await DesktopHarness.make()
		h.viewModel.performDeleteVM(Samples.linux("Fedora", state: .error))
		#expect(await eventually { !h.viewModel.hasVM("Fedora") })
		#expect(h.viewModel.selectedName == "Alpine")
	}

	@Test func deletingTheShownVMSelectsTheFirst() async {
		let h = await DesktopHarness.make()
		h.viewModel.performDeleteVM(Samples.linux("Alpine"))
		#expect(await eventually { !h.viewModel.hasVM("Alpine") })
		#expect(await eventually { h.viewModel.selectedName == "Debian" })
	}

	@Test func aRefusedReferenceDoesNotStopTheRest() async {
		let h = await DesktopHarness.make()
		h.stub.fail("addDisk", with: Self.refusal)
		h.viewModel.addDisks("Alpine", [
			.image(path: "/Users/demo/a.img"), .image(path: "/Users/demo/b.img"),
			.iso(path: "/Users/demo/c.iso"),
		])
		#expect(await eventually { h.viewModel.toasts.contains { $0.message == "Added 2 disks" } })
		#expect(h.viewModel.presentedError?.title == "Adding \u{201C}a.img\u{201D} failed")
		#expect(h.stub.addedDisks.count == 2)
	}

	// A view model that went with its connection sends nothing it was asked before it went.
	@Test func aViewModelThatWentSendsNothing() async throws {
		let h = await DesktopHarness.make()
		var other: VMListViewModel? = VMListViewModel(
			api: h.stub, store: h.store, operations: h.operations, terminals: h.terminals,
			previews: h.previews, canvases: h.canvases, tornTabs: h.tornTabs)
		weak var gone = other
		other?.openWindow("Debian")
		other?.addDisk("Alpine", .storage(name: "data", sizeBytes: 8 << 30))
		other = nil
		#expect(gone == nil)
		try await Task.sleep(for: .milliseconds(200))
		#expect(!h.stub.calls.contains("openWindow"))
		#expect(!h.stub.calls.contains("addDisk"))
	}

	// Nor does a call in flight keep it alive (V12): released while its save is parked in the
	// daemon, it is gone at once, and the save it sent still lands for everyone else.
	@Test func aCallInFlightDoesNotHoldTheViewModel() async {
		let h = await DesktopHarness.make([Samples.linuxSafeRun("Debian")])
		h.stub.stalled = ["safeSave"]
		var other: VMListViewModel? = VMListViewModel(
			api: h.stub, store: h.store, operations: h.operations, terminals: h.terminals,
			previews: h.previews, canvases: h.canvases, tornTabs: h.tornTabs)
		weak var gone = other
		other?.safeSave("Debian", to: "Debian kept")
		#expect(await eventually { h.stub.calls.contains("safeSave") })
		other = nil
		#expect(gone == nil)
		h.stub.stalled = []
		#expect(await eventually { h.viewModel.hasVM("Debian kept") })
	}
}
