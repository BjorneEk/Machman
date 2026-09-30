//
//  Overlays.swift
//  MachmanRender
//
//  The window's corner overlay: toasts pushed through the view model the way its own
//  diffs push them, and a progress card from an operation event (a VM copy in flight).
//

import SwiftUI
import MachmanAPI
import MachmanUI
import MachmanFixtures
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

enum OverlayScenes {
	static let all: [RenderScene] = [
		RenderScene(
			"overlay.notifications", "NotificationOverlay: toasts and a copy progress card",
			widths: [420], height: 300
		) { ctx in
			ctx.stub.emit(.operationChanged(op: Samples.copyOperation()))
			Offscreen.pump(until: { !ctx.operations.operations.isEmpty })
			ctx.viewModel.pushToast(symbol: MachmanSymbols.start, message: "Debian started")
			ctx.viewModel.pushToast(
				symbol: MachmanSymbols.warning, message: "Fedora hit an error",
				tint: MachmanColors.warning)
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
	]
}
