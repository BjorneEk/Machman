//
//  Popovers.swift
//  MachmanRender
//
//  Toolbar popovers, sheets and the toolbar's own items, each drawn at its fitting size.
//  The toolbar items are shown for every VM of the sample library, so each state a list
//  row can take is on one picture.
//

import SwiftUI
import MachmanAPI
import MachmanUI
import MachmanFixtures
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

enum PopoverScenes {
	// One toolbar item per library VM, stacked (`nil` = the no-selection indicator).
	@MainActor
	static func perVM(
		_ ctx: SceneContext, includeNone: Bool = false,
		_ item: @escaping @MainActor (VMInfo?) -> AnyView
	) -> AnyView {
		let vms: [VMInfo?] = ctx.viewModel.vms.map { $0 } + (includeNone ? [nil] : [])
		return AnyView(
			VStack(alignment: .leading, spacing: 10) {
				ForEach(Array(vms.enumerated()), id: \.offset) { _, vm in
					item(vm)
				}
			}
			.padding(12))
	}

	// The mount guide for one of the first VM's mounts.
	static func mountGuide(
		_ suffix: String, _ summary: String, vms: @escaping () -> [VMInfo],
		mount id: String = Samples.srcMountID
	) -> RenderScene {
		RenderScene("sheet.mount-help\(suffix)", "MountHelpSheet, \(summary)", vms: vms) { ctx in
			let mount = ctx.vm.mounts.first { $0.id == id }!
			return AnyView(MountHelpSheet(vm: ctx.vm, mount: mount))
		}
	}

	// One guide page alone, at the sheet's text width (560 − 2 × 22), fitting height.
	static func guidePage(
		_ name: String, _ summary: String, tab: GuestSetupHelpSheet.GuestTab,
		vms: @escaping () -> [VMInfo]
	) -> RenderScene {
		RenderScene(
			"sheet.guest-setup-help.page.\(name)", "GuestSetupGuidePage, \(summary)",
			widths: [nil], vms: vms
		) { ctx in
			let escalation = GuestSetupCommands.escalations(
				for: tab == .bsd ? .bsd : tab == .macOS ? .macOS : .linux)[0]
			return AnyView(
				VStack(alignment: .leading, spacing: 12) {
					GuestSetupGuidePage(vm: ctx.vm, tab: tab, escalation: escalation)
				}
				.frame(width: 516, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.vertical, 8))
		}
	}

	// The activity list as the real flows fill it (PR5): a cancelled copy, a finished and a
	// failed import (operation events), then Debian's Screen Recording warning (a log event).
	@MainActor
	static func seedActivity(_ ctx: SceneContext) {
		for op in [Samples.cancelledCopyFrom(), Samples.finishedImport(), Samples.failedImport()] {
			ctx.stub.emit(.operationChanged(op: op))
			Offscreen.pump(until: { ctx.operations.activity.contains(
				key: ActivityEntry.operationKey(op.id)) })
		}
		ctx.stub.emit(.log(vm: "Debian", level: .warning, message: Samples.screenRecordingWarning))
		Offscreen.pump(until: { ctx.operations.activity.entries.count == 4 })
	}

	static let all: [RenderScene] = [
		RenderScene("popover.activity", "ActivityPopover, four entries, newest first") { ctx in
			seedActivity(ctx)
			return AnyView(ActivityPopover(activity: ctx.operations.activity))
		},
		RenderScene("popover.activity.empty", "ActivityPopover, nothing yet") { ctx in
			AnyView(ActivityPopover(activity: ctx.operations.activity))
		},
		RenderScene(
			"toolbar.activity", "ActivityButton with two unseen problems, and with none"
		) { ctx in
			seedActivity(ctx)
			return AnyView(HStack(spacing: 20) {
				ActivityButton(activity: ctx.operations.activity)
				ActivityButton(activity: ActivityLog())
			}
			.padding(16))
		},
		RenderScene("popover.add", "AddPopover tiles") { ctx in
			AnyView(AddPopover(viewModel: ctx.viewModel, vm: ctx.vm))
		},
		RenderScene("popover.add.new-disk", "AddPopover's New Disk form") { ctx in
			AnyView(AddPopover(viewModel: ctx.viewModel, vm: ctx.vm, newDisk: true))
		},
		RenderScene(
			"popover.add.new-disk.taken", "New Disk form, a name the VM already uses"
		) { ctx in
			AnyView(AddPopover(
				viewModel: ctx.viewModel, vm: ctx.vm, newDisk: true,
				diskName: "system", diskSize: "64"))
		},
		RenderScene(
			"popover.add.new-disk.bad-size", "New Disk form, a size it can't read"
		) { ctx in
			AnyView(AddPopover(
				viewModel: ctx.viewModel, vm: ctx.vm, newDisk: true,
				diskName: "data", diskSize: "lots"))
		},
		RenderScene(
			"popover.add.new-disk.decimal", "New Disk form, a decimal size in GB"
		) { ctx in
			AnyView(AddPopover(
				viewModel: ctx.viewModel, vm: ctx.vm, newDisk: true,
				diskName: "data", diskSize: "1.5"))
		},
		RenderScene("popover.vm-picker", "VMPickerPopover, every row state") { ctx in
			AnyView(VMPickerPopover(viewModel: ctx.viewModel))
		},
		// H49 (C10): “i” typed, ↓ pressed twice: Sequoia is the row Return opens.
		RenderScene(
			"popover.vm-picker.highlight", "VMPickerPopover, “i” typed and Sequoia highlighted"
		) { ctx in
			AnyView(VMPickerPopover(viewModel: ctx.viewModel, query: "i", highlight: "Sequoia"))
		},
		RenderScene("popover.vm-picker.templates", "VMPickerPopover's New VM templates") { ctx in
			AnyView(VMPickerPopover(viewModel: ctx.viewModel, templates: true))
		},
		RenderScene(
			"popover.vm-picker.mac-source", "VMPickerPopover's macOS install source"
		) { ctx in
			AnyView(VMPickerPopover(viewModel: ctx.viewModel, macSource: true))
		},
		RenderScene(
			"popover.vm-picker.not-responding", "VMPickerPopover, Debian's vmhost not responding",
			vms: Samples.libraryWithStalledHost
		) { ctx in
			AnyView(VMPickerPopover(viewModel: ctx.viewModel))
		},
		// W4: with no VMs at all the list says so, not “No VMs match “””.
		RenderScene("popover.vm-picker.empty", "VMPickerPopover with no VMs", vms: { [] }) { ctx in
			AnyView(VMPickerPopover(viewModel: ctx.viewModel))
		},
		RenderScene("sheet.copy-vm", "CopyVMSheet") { ctx in
			AnyView(CopyVMSheet(vm: ctx.vm, viewModel: ctx.viewModel))
		},
		RenderScene(
			"sheet.copy-vm.hidden-name", "CopyVMSheet, a name starting with a dot"
		) { ctx in
			AnyView(CopyVMSheet(vm: ctx.vm, viewModel: ctx.viewModel, name: ".Debian copy"))
		},
		RenderScene("sheet.copy-vm.taken", "CopyVMSheet, a name another VM has") { ctx in
			AnyView(CopyVMSheet(vm: ctx.vm, viewModel: ctx.viewModel, name: "Sequoia"))
		},
		RenderScene(
			"sheet.copy-vm.mounts", "CopyVMSheet, two mounts, the sshfs one left out",
			vms: { [Samples.linuxWithMounts()] }
		) { ctx in
			AnyView(CopyVMSheet(
				vm: ctx.vm, viewModel: ctx.viewModel, excludedMountIDs: [Samples.notesMountID]))
		},
		RenderScene(
			"sheet.copy-vm.small-disk", "CopyVMSheet, a 500 MB disk (under one GB)",
			vms: { [Samples.linuxSmallDisk()] }
		) { ctx in
			AnyView(CopyVMSheet(vm: ctx.vm, viewModel: ctx.viewModel))
		},
		RenderScene(
			"sheet.copy-vm.long-names", "CopyVMSheet, disks with long names and paths",
			vms: { [Samples.linuxLongDiskNames()] }
		) { ctx in
			AnyView(CopyVMSheet(vm: ctx.vm, viewModel: ctx.viewModel))
		},
		RenderScene(
			"sheet.safe-save", "SafeSaveSheet, a running safe run",
			vms: {
				var vm = Samples.linux("Debian", state: .running)
				vm.safeRun = true
				return [vm]
			}
		) { ctx in
			AnyView(SafeSaveSheet(vm: ctx.vm, viewModel: ctx.viewModel))
		},
		RenderScene(
			"sheet.safe-save.blank", "SafeSaveSheet, a blank name",
			vms: { [Samples.linuxSafeRun()] }
		) { ctx in
			AnyView(SafeSaveSheet(vm: ctx.vm, viewModel: ctx.viewModel, name: "   "))
		},
		RenderScene("sheet.guest-setup-help", "GuestSetupHelpSheet, Linux guest") { ctx in
			AnyView(GuestSetupHelpSheet(vm: ctx.vm))
		},
		RenderScene(
			"sheet.guest-setup-help.bsd", "GuestSetupHelpSheet, the BSD tab (opens on doas)",
			vms: { [Samples.linuxReverseApproved()] }
		) { ctx in
			AnyView(GuestSetupHelpSheet(vm: ctx.vm, tab: .bsd))
		},
		RenderScene(
			"sheet.guest-setup-help.bsd-root", "GuestSetupHelpSheet, the BSD tab run as root",
			vms: { [Samples.linuxReverseApproved()] }
		) { ctx in
			AnyView(GuestSetupHelpSheet(vm: ctx.vm, tab: .bsd, escalation: .root))
		},
		// Whole guide pages at the sheet's text width, below the fold included.
		guidePage("linux", "Linux", tab: .linux, vms: { [Samples.linux("Debian")] }),
		guidePage("macos", "macOS", tab: .macOS, vms: { [Samples.macOS("Sequoia")] }),
		guidePage("bsd", "BSD, key not approved", tab: .bsd, vms: { [Samples.linux("Debian")] }),
		guidePage(
			"bsd-approved", "BSD, approved key", tab: .bsd,
			vms: { [Samples.linuxReverseApproved()] }),
		guidePage("info", "Info", tab: .info, vms: { [Samples.linux("Debian")] }),
		mountGuide("", "a Linux guest mounting by hand", vms: { [Samples.linuxManualMount()] }),
		mountGuide(".automounted", "Guest Setup automounts the share", vms: { [Samples.linux()] }),
		mountGuide(".kernel", "a kernel-boot guest", vms: { [Samples.kernelBoot()] }),
		mountGuide(
			".sshfs", "an sshfs folder", vms: { [Samples.linuxWithMounts()] },
			mount: Samples.notesMountID),
		mountGuide(".macos", "a macOS guest", vms: { [Samples.macOSWithMount()] }),
		RenderScene("sheet.rosetta-help", "RosettaHelpSheet") { _ in AnyView(RosettaHelpSheet()) },
		RenderScene("sheet.rosetta-help.root", "RosettaHelpSheet run as root") { _ in
			AnyView(RosettaHelpSheet(escalation: .root))
		},
		RenderScene("sheet.mac-switch", "MacSwitchSheet (switch a VM to macOS)") { ctx in
			AnyView(MacSwitchSheet(viewModel: ctx.viewModel, vm: ctx.vm("Alpine")))
		},
		// H41: installing is stop-first, so a running VM's sheet waits with the reason.
		RenderScene(
			"sheet.mac-switch.running", "MacSwitchSheet for a running VM (both sources wait)"
		) { ctx in
			AnyView(MacSwitchSheet(viewModel: ctx.viewModel, vm: ctx.vm("Debian")))
		},
		// D32 (K4): the switch asks where to install; a disk picked shows what that erases, and
		// one smaller than a new disk carries the warning (K15).
		RenderScene(
			"sheet.mac-switch.disks", "MacSwitchSheet with several disks, the small one picked",
			vms: { [Samples.linuxBeforeMacSwitch()] }
		) { ctx in
			AnyView(MacSwitchSheet(viewModel: ctx.viewModel, vm: ctx.vm, pick: "storage:data"))
		},
		// H45: Install macOS… on a Mac whose install failed is a retry, not a switch.
		RenderScene(
			"sheet.mac-switch.retry", "MacSwitchSheet for a Mac whose install failed",
			vms: { [Samples.macOSFailedInstall()] }
		) { ctx in
			AnyView(MacSwitchSheet(viewModel: ctx.viewModel, vm: ctx.vm))
		},
		RenderScene("toolbar.indicator", "VMIndicatorCluster per VM, and with none") { ctx in
			perVM(ctx, includeNone: true) { vm in
				AnyView(VMIndicatorCluster(viewModel: ctx.viewModel, vm: vm))
			}
		},
		RenderScene(
			"toolbar.indicator.not-responding",
			"VMIndicatorCluster per VM, Debian's vmhost not responding",
			vms: Samples.libraryWithStalledHost
		) { ctx in
			perVM(ctx) { vm in
				AnyView(VMIndicatorCluster(viewModel: ctx.viewModel, vm: vm))
			}
		},
		RenderScene(
			"toolbar.indicator.long-name", "VMIndicatorCluster, a VM name longer than the cap",
			vms: { [Samples.longNamedLinux()] }
		) { ctx in
			AnyView(VMIndicatorCluster(viewModel: ctx.viewModel, vm: ctx.vm).padding(12))
		},
		RenderScene("toolbar.start-stop", "StartStopGroup per VM") { ctx in
			perVM(ctx) { vm in
				AnyView(StartStopGroup(viewModel: ctx.viewModel, vm: vm!))
			}
		},
		RenderScene(
			"toolbar.start-stop.stopping", "StartStopGroup while a guest shuts down",
			vms: { [Samples.stoppingLinux()] }
		) { ctx in
			AnyView(StartStopGroup(viewModel: ctx.viewModel, vm: ctx.vm).padding(12))
		},
		RenderScene("toolbar.window-toggle", "WindowToggleItem per VM") { ctx in
			perVM(ctx) { vm in
				AnyView(WindowToggleItem(viewModel: ctx.viewModel, vm: vm!))
			}
		},
	]
}
