//
//  RestartToUpdateBanner.swift
//  MachmanDesktopUI
//
//  E22 (decision 9): leads the inspector of a VM still run by an older vmhost, whose settings
//  stay locked until it restarts. One sentence; the reason is the tooltip.
//

import SwiftUI
import MachmanUI

struct RestartToUpdateBanner: View {
	let message: String

	var body: some View {
		Label {
			Text(message)
				.fontWeight(.medium)
				.fixedSize(horizontal: false, vertical: true)
		} icon: {
			Image(systemName: MachmanSymbols.warning)
				.foregroundStyle(MachmanColors.warning)
		}
		.font(.callout)
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.vertical, 10)
		.help("It still runs on an older Machman, so its settings stay locked until it restarts")
	}
}
