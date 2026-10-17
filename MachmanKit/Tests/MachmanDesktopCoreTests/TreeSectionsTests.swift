//
//  TreeSectionsTests.swift
//  MachmanDesktopCoreTests
//
//  Which device-tree sections show (N1): no section ever hid on empty children, so a filter
//  that matched nothing left every header childless. Now a filtered section needs a matching
//  row, and an empty one stays only where the tree is its add path (SSH, Kernel, Initramfs).
//  Also the kernel rows, moved out of the view for the tree and the selection prune.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
@testable import MachmanDesktopCore

struct TreeSectionsTests {
	@Test func aFilterHidesEverySectionWithoutARow() {
		for section in TreeSection.allCases {
			#expect(!TreeSection.isVisible(section, rows: 0, filtering: true))
		}
	}

	@Test func emptySectionsHideUnlessTheTreeIsTheirAddPath() {
		let shown = TreeSection.allCases.filter {
			TreeSection.isVisible($0, rows: 0, filtering: false)
		}
		#expect(shown == [.ssh, .kernel, .initramfs])
	}

	@Test func rowsAlwaysShow() {
		for section in TreeSection.allCases {
			#expect(TreeSection.isVisible(section, rows: 1, filtering: true))
			#expect(TreeSection.isVisible(section, rows: 3, filtering: false))
		}
	}

	// N2: an empty section that stays (SSH with no session, Kernel before its first file)
	// drew a chevron that unfolded nothing.
	@Test func anEmptySectionDoesNotFold() {
		#expect(!TreeSection.folds(rows: 0, previewing: false))
	}

	@Test func rowsOrADragPreviewFold() {
		#expect(TreeSection.folds(rows: 1, previewing: false))
		#expect(TreeSection.folds(rows: 0, previewing: true))
	}

	@Test func kernelEntriesListOwnedFilesAndTheActiveReference() {
		var vm = Samples.kernelBoot()
		let dir = "\(Samples.vmsRoot)/Kernel Lab/kernels"
		#expect(vm.kernelTreeEntries(role: .kernel) == [
			KernelTreeEntry(
				id: "\(dir)/kernel/6.12/vmlinuz", label: "6.12", owned: true, active: true),
			KernelTreeEntry(
				id: "\(dir)/kernel/6.6-lts/Image", label: "6.6-lts", owned: true, active: false),
		])
		#expect(vm.kernelTreeEntries(role: .initramfs) == [
			KernelTreeEntry(
				id: "\(dir)/initramfs/6.12/initrd.img", label: "6.12", owned: true, active: true),
		])
		vm.boot.kernel?.kernelPath = "/Users/demo/Downloads/vmlinuz"
		let entries = vm.kernelTreeEntries(role: .kernel)
		#expect(entries.map(\.active) == [false, false, true])
		#expect(entries.last == KernelTreeEntry(
			id: "/Users/demo/Downloads/vmlinuz", label: "vmlinuz", owned: false, active: true))
	}

	@Test func kernelSectionsFollowKernelBoot() {
		#expect(!Samples.macOS().showsKernelSections)
		#expect(!Samples.linux().showsKernelSections)
		#expect(Samples.kernelBoot().showsKernelSections)
		#expect(!Samples.kernelBoot().kernelSectionParked)
		// Back to EFI with the files kept: still shown, parked.
		var parked = Samples.kernelBoot()
		parked.boot.mode = .efi
		#expect(parked.showsKernelSections && parked.kernelSectionParked)
	}

	// N3 (the user's review-4 note): the sections followed the draft's presence, not what it
	// holds, so an empty draft left behind by kernel boot kept them, parked, for good.
	@Test("N3: an EFI VM whose kernel draft holds nothing shows no kernel sections")
	func anEmptyParkedDraftShowsNoSections() {
		var vm = Samples.linux()
		vm.boot.kernel = KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		vm.boot.ownedKernels = nil
		#expect(vm.boot.mode == .efi)
		#expect(!vm.showsKernelSections)
	}

	// K1: a command line is something kept, so a draft holding only one keeps both sections,
	// parked and without rows (the Kernel inspector shows the line); whitespace is nothing.
	@Test("N3: a parked draft holding only a command line keeps both sections, parked")
	func aCommandLineKeepsTheParkedSections() {
		var vm = Samples.kernelParkedCommandLineOnly()
		#expect(vm.showsKernelSections && vm.kernelSectionParked)
		#expect(vm.kernelDraft == KernelDraftContents(
			hasFiles: false, hasCommandLine: true, missingKernel: true))
		#expect(vm.kernelTreeEntries(role: .kernel).isEmpty)
		#expect(vm.kernelTreeEntries(role: .initramfs).isEmpty)
		#expect(TreeSection.isVisible(.kernel, rows: 0, filtering: false))
		#expect(TreeSection.isVisible(.initramfs, rows: 0, filtering: false))
		vm.boot.kernel?.commandLine = " \n "
		#expect(!vm.showsKernelSections)
	}

	// D31 (K3): a switch to macOS keeps the kernel files and draft; they show parked, as the
	// VM's own files (never as external references).
	@Test("D31: a macOS VM with kernel files shows them parked")
	func aMacOSVMShowsItsKernelFilesParked() {
		let vm = Samples.macOSWithKernelFiles()
		#expect(vm.showsKernelSections && vm.kernelSectionParked)
		#expect(vm.kernelTreeEntries(role: .kernel).map(\.owned) == [true, true])
		#expect(vm.kernelTreeEntries(role: .initramfs).map(\.owned) == [true])
		#expect(!vm.kernelBootMissingKernel)
		#expect(!Samples.macOS().showsKernelSections)
	}

	// T28: the tree's badge and the Kernel inspector each wrote the rule; now one predicate
	// holds it — only kernel boot without a kernel, never a parked draft without one.
	@Test("T28: the tree's and the inspector's no-kernel warning read one rule")
	func oneNoKernelRule() {
		#expect(Samples.kernelBootEmpty().kernelBootMissingKernel)
		#expect(!Samples.kernelBoot().kernelBootMissingKernel)
		#expect(Samples.kernelParkedCommandLineOnly().kernelDraft.missingKernel)
		#expect(!Samples.kernelParkedCommandLineOnly().kernelBootMissingKernel)
		#expect(!Samples.linux().kernelBootMissingKernel)
	}

	@Test func serialPortsListConsolesThenUARTs() {
		let ports = Samples.kernelBoot().allSerialPorts
		#expect(ports.map(\.kind) == [.console, .uart])
		#expect(Samples.bareLinux().allSerialPorts.isEmpty)
	}
}
