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
		RenderScene(
			"overlay.settings-set-aside",
			"NotificationOverlay: an unreadable settings file set aside at launch",
			widths: [420], height: 300
		) { ctx in
			// A real store over an unreadable file in the sandbox: it sets the file aside.
			let dir = RenderSandbox.dataDir.appendingPathComponent("set-aside-\(UUID())")
			let url = dir.appendingPathComponent("TerminalProfiles.json")
			try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			try? Data("not json".utf8).write(to: url)
			ctx.viewModel.announceSetAsideSettings([TerminalProfileStore(fileURL: url)])
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
		RenderScene(
			"overlay.list-stale", "NotificationOverlay: the VM list failed to refresh",
			widths: [420], height: 300
		) { ctx in
			// The store's first retry is a second out — after the snapshot.
			ctx.stub.fail("listVMs", with: MachmanError(
				code: .timeout,
				message: "no reply to vm.list after 30s — the serving process may be hung"))
			Task { await ctx.store.reload() }
			Offscreen.pump(until: { ctx.store.listProblem != nil })
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
		RenderScene(
			"overlay.finished-cards",
			"NotificationOverlay: a running copy beside a finished import and a cancelled copy",
			widths: [420], height: 360
		) { ctx in
			// The finished cards linger 5 s — longer than the snapshot takes.
			for op in [Samples.copyOperation(), Samples.finishedImport(), Samples.cancelledCopy()] {
				ctx.stub.emit(.operationChanged(op: op))
			}
			Offscreen.pump(until: { ctx.operations.operations.count == 3 })
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
		RenderScene(
			"overlay.cards.not-cancellable",
			"NotificationOverlay: a running copy beside a Rosetta install that can't be cancelled",
			widths: [420], height: 300
		) { ctx in
			for op in [Samples.copyOperation(), Samples.rosettaInstallOperation()] {
				ctx.stub.emit(.operationChanged(op: op))
			}
			Offscreen.pump(until: { ctx.operations.operations.count == 2 })
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
		RenderScene(
			"overlay.cards.copy-from",
			"NotificationOverlay: a VM copy titled by the copy, labelled by its source",
			widths: [420], height: 300
		) { ctx in
			ctx.stub.emit(.operationChanged(op: Samples.copyFromOperation()))
			Offscreen.pump(until: { !ctx.operations.operations.isEmpty })
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
		RenderScene(
			"overlay.cards.failed-long",
			"NotificationOverlay: a failed import whose message is a whole sentence",
			widths: [420], height: 320
		) { ctx in
			ctx.stub.emit(.operationChanged(op: Samples.failedImport()))
			Offscreen.pump(until: { !ctx.operations.operations.isEmpty })
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
		// F6: the engine's warning arrives as a log event; the toast wraps at its cap.
		RenderScene(
			"overlay.toasts.long-warning",
			"NotificationOverlay: a short toast above Debian's Screen Recording warning",
			widths: [420, 900], height: 300
		) { ctx in
			ctx.viewModel.pushToast(symbol: MachmanSymbols.start, message: "Debian started")
			ctx.stub.emit(.log(
				vm: "Debian", level: .warning, message: Samples.screenRecordingWarning))
			Offscreen.pump(until: { ctx.viewModel.toasts.count == 2 })
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
		// W3: the import refusal's card reads the engine's sentence (E28: was a struct dump).
		RenderScene(
			"overlay.cards.failed-qcow2",
			"NotificationOverlay: a refused qcow2 import",
			widths: [420], height: 320
		) { ctx in
			ctx.stub.emit(.operationChanged(op: Samples.failedQcow2Import()))
			Offscreen.pump(until: { !ctx.operations.operations.isEmpty })
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
		// W3: a boot warning names its VM once, from a current daemon and from an older one.
		RenderScene(
			"overlay.toasts.boot-warning",
			"NotificationOverlay: boot warnings from a current and an older daemon",
			widths: [420, 900], height: 300
		) { ctx in
			ctx.stub.emit(.log(vm: "Debian", level: .warning, message: Samples.bootWarning))
			ctx.stub.emit(.log(
				vm: "Alpine", level: .warning, message: Samples.olderDaemonBootWarning("Alpine")))
			Offscreen.pump(until: { ctx.viewModel.toasts.count == 2 })
			return AnyView(NotificationOverlay(
				viewModel: ctx.viewModel, operations: ctx.operations))
		},
	]
}
