//
//  VMIndicator.swift
//  MachmanDesktopUI
//
//  The toolbar's leading VM cluster (1.0.4 UI): status dot + name + boot-kind subtitle with
//  a chevron that fades in on hover, opening the VM picker popover. Beside it, the inert
//  safe-mode chip. RULE: toolbar controls are native items (bare Button/Toggle/ControlGroup)
//  so macOS supplies the hover + glass shapes; custom styling exists only INSIDE labels.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct VMIndicatorCluster: View {
	@ObservedObject var viewModel: VMListViewModel
	// nil = nothing selected; the indicator still renders so the picker stays reachable
	// (it is the ONLY way to switch VMs — the sidebar shows one VM's device tree).
	let vm: VMInfo?
	@State private var pickerShown = false
	// Opens the picker on its New VM template page (File ▸ New VM…).
	@State private var pickerTemplates = false
	@State private var hovering = false

	var body: some View {
		Button {
			pickerShown.toggle()
		} label: {
			// Titled by the VM for the toolbar's » menu; the bar shows the whole cluster (H33).
			Label {
				Text(vm?.name ?? "No VM")
			} icon: {
				cluster
			}
			.labelStyle(.iconOnly)
		}
		.buttonStyle(.plain)
		// VoiceOver reads the cluster as it reads in the bar: the state, the name, the boot
		// mode (the title alone would drop the state).
		.accessibilityLabel(spoken)
		.onHover { hovering = $0 }
		// The name truncates at 220 pt; the tooltip carries all of it (L5).
		.help(vm.map { "\($0.name) — Switch VM" } ?? "Switch VM")
		.popover(isPresented: $pickerShown, arrowEdge: .bottom) {
			// Keyed by the page: ⌘N while the picker already shows its list re-seeds it.
			VMPickerPopover(viewModel: viewModel, templates: pickerTemplates)
				.id(pickerTemplates)
		}
		// File ▸ New VM… (⌘N): open on the template page. A request made while the main
		// window was closed is picked up when it reappears; deferred, because the request
		// is cleared (published) as the chooser opens.
		.onChange(of: viewModel.newVMChooserRequested) { _, requested in
			if requested { DispatchQueue.main.async { showChooser() } }
		}
		.onAppear {
			if viewModel.newVMChooserRequested {
				DispatchQueue.main.async { showChooser() }
			}
		}
		// The next ordinary open shows the VM list again.
		.onChange(of: pickerShown) { _, shown in
			if !shown { pickerTemplates = false }
		}
	}

	private var spoken: String {
		guard let vm else { return "No VM" }
		let mode = vm.isUnresponsive ? "Not responding" : vm.boot.mode.displayLabel
		return [vm.stateLabel, vm.name, mode].joined(separator: ", ")
	}

	// Status dot, name and boot badge in a glass capsule, with the chevron that fades in on
	// hover.
	private var cluster: some View {
		HStack(spacing: 7) {
			if let vm {
				VMStatusDot(vm: vm)
				VStack(alignment: .leading, spacing: 1) {
					// Middle: copies differ at the end ("… copy 2"), so keep both ends.
					Text(vm.name)
						.font(.system(size: 12.5, weight: .semibold))
						.lineLimit(1)
						.truncationMode(.middle)
					if vm.isUnresponsive {
						NotRespondingBadge(size: 9)
					} else {
						BootBadge(mode: vm.boot.mode, size: 9)
					}
				}
				.frame(maxWidth: 220, alignment: .leading)
			} else {
				Text("No VM")
					.font(.system(size: 12.5, weight: .semibold))
					.foregroundStyle(.secondary)
			}
			Image(systemName: MachmanSymbols.pickerChevron)
				.font(.system(size: 8, weight: .bold))
				.foregroundStyle(.secondary)
				.opacity(hovering || pickerShown ? 1 : 0)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 4)
		.machmanGlassCapsule()
		.contentShape(Capsule())
		.animation(.easeOut(duration: 0.12), value: hovering)
	}

	private func showChooser() {
		guard viewModel.newVMChooserRequested else { return }
		viewModel.newVMChooserRequested = false
		pickerTemplates = true
		pickerShown = true
	}
}

// Safe-mode chip: sized like a toolbar control but completely inert — no accent tint, no
// hover or press feedback, tooltip only. Deliberately NOT a Button/Toggle so no control
// styling can kick in.
struct SafeModeChip: View {
	var body: some View {
		// Titled for the toolbar's » menu; the bar shows the shield (H33).
		Label("Safe Mode", systemImage: MachmanSymbols.safe)
			.labelStyle(.iconOnly)
			.font(.system(size: 13, weight: .medium))
			.foregroundStyle(MachmanColors.safeMode)
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.machmanGlassCapsule()
			.help("Safe mode — changes are discarded on stop")
	}
}
