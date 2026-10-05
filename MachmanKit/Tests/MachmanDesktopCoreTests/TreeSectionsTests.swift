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

	@Test func serialPortsListConsolesThenUARTs() {
		let ports = Samples.kernelBoot().allSerialPorts
		#expect(ports.map(\.kind) == [.console, .uart])
		#expect(Samples.bareLinux().allSerialPorts.isEmpty)
	}
}
