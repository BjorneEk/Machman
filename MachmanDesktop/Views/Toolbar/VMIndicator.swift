//
//  VMIndicator.swift
//  MachmanDesktop
//
//  The toolbar's leading VM cluster (1.0.4 UI): status dot + name + boot-kind subtitle with
//  a chevron that fades in on hover, opening the VM picker popover. Beside it, the inert
//  safe-mode chip. RULE: toolbar controls are native items (bare Button/Toggle/ControlGroup)
//  so macOS supplies the hover + glass shapes; custom styling exists only INSIDE labels.
//

import SwiftUI
import MachmanUI
import MachmanAPI

extension VMInfo {
	// Whether the VM would boot with a display. nil devices = a pre-1.0.4 daemon, where
	// graphics were unconditional — treat as present.
	var hasEnabledGraphics: Bool {
		guard let devices else { return true }
		return devices.contains { $0.kind == .graphics && $0.enabled }
	}
}

struct VMIndicatorCluster: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@State private var pickerShown = false
	@State private var hovering = false

	var body: some View {
		Button {
			pickerShown.toggle()
		} label: {
			HStack(spacing: 7) {
				StatusDot(state: vm.state)
				VStack(alignment: .leading, spacing: 1) {
					Text(vm.name)
						.font(.system(size: 12.5, weight: .semibold))
						.lineLimit(1)
						.truncationMode(.tail)
					BootBadge(mode: vm.boot.mode, size: 9)
				}
				.frame(maxWidth: 220, alignment: .leading)
				Image(systemName: MachmanSymbols.pickerChevron)
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(.secondary)
					.opacity(hovering || pickerShown ? 1 : 0)
			}
			.padding(.horizontal, 2)
			.padding(.vertical, 2)
			.contentShape(Rectangle())
			.animation(.easeOut(duration: 0.12), value: hovering)
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.help("Switch VM")
		.popover(isPresented: $pickerShown, arrowEdge: .bottom) {
			VMPickerPopover(viewModel: viewModel)
		}
	}
}

// Safe-mode chip: sized like a toolbar control but completely inert — no accent tint, no
// hover or press feedback, tooltip only. Deliberately NOT a Button/Toggle so no control
// styling can kick in.
struct SafeModeChip: View {
	var body: some View {
		Image(systemName: MachmanSymbols.safe)
			.font(.system(size: 13, weight: .medium))
			.foregroundStyle(MachmanColors.safeMode)
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.background(Capsule().fill(Color.primary.opacity(0.07)))
			.help("Safe mode — changes are discarded on stop")
	}
}
