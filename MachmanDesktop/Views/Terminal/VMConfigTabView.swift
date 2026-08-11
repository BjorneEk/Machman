//
//  VMConfigTabView.swift
//  MachmanDesktop
//
//  The VM's configuration page — the fixed first tab (gear) of its pane. This is the former
//  MainVMView body: a preview + disks row over a config + host-mounts row. The VM's name/run/
//  delete controls and window-focus tracking now live on the enclosing VMTabContainerView (they
//  stay put across tab switches), so this view is purely the config content.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct VMConfigTabView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel
	@State private var previewWidth: CGFloat = 0

	var body: some View {
		VStack {
			HStack {
				PreviewView(viewModel: viewModel, previews: viewModel.previewImages)
					.frame(minWidth: 170)
				Spacer()
				ConfigVMDisksView(vm: vm, viewModel: viewModel)
					.frame(minWidth: 200)
					.frame(minHeight: 250)
			}
			.padding(.vertical, 0)
			Divider()
			// Top-aligned: the two columns have different vertical greed (the left ends in a
			// Spacer, the right doesn't), so center alignment let the mounts box drift.
			HStack(alignment: .top) {
				ConfigVMView(vm: vm, viewModel: viewModel)
					.frame(width: previewWidth)
					.frame(maxHeight: .infinity, alignment: .top)
				ConfigVMHostMountsView(vm: vm, viewModel: viewModel)
					.frame(minWidth: 200)
					.frame(maxHeight: .infinity, alignment: .top)
			}
		}
		.onPreferenceChange(PreviewWidthKey.self) { width in
			previewWidth = width
		}
		.padding()
	}
}
