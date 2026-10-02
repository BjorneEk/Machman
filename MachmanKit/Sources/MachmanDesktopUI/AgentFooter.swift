//
//  AgentFooter.swift
//  MachmanDesktopUI
//
//  The quiet status line under the device tree: the Machman Agent the app talks to, its
//  version, and how many VMs run. Its own view so the render tool can draw it.
//

import SwiftUI
import MachmanUI

struct AgentFooter: View {
	let version: String?
	let running: Int

	var body: some View {
		HStack(spacing: 6) {
			Circle()
				.fill(MachmanColors.stateRunning)
				.frame(width: 6, height: 6)
			Text(version.map { "Machman Agent \($0)" } ?? "Machman Agent")
			Text("·").foregroundStyle(.tertiary)
			Text("\(running) running")
			Spacer()
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}
}
