//
//  TransferProgressView.swift
//  MachmanDesktop
//
//  The generic transfer popup: disk imports, promotes, and safe-run shadow builds all emit
//  copyProgress events outside the duplicate sheet — this is where they show. Presented
//  while viewModel.transfers is non-empty; dismissal is data-driven (bars complete or fail),
//  never the user's.
//

import SwiftUI
import MachmanUI

struct TransferProgressView: View {
	@ObservedObject var viewModel: VMListViewModel

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Copying…", systemImage: MachmanSymbols.promoteDisk)
				.font(.headline)
			ForEach(viewModel.transfers.keys.sorted(), id: \.self) { vm in
				if let transfer = viewModel.transfers[vm] {
					VStack(alignment: .leading, spacing: 4) {
						Text(vm)
							.font(.caption)
						ProgressView(
							value: Double(transfer.done),
							total: Double(max(transfer.total, 1)))
							.frame(width: 280)
					}
				}
			}
		}
		.padding(20)
	}
}

#Preview {
}
