//
//  WindowErrorAlert.swift
//  MachmanDesktopUI
//
//  The error alert, in whichever window should show it (H40, C22). VMListViewModel queues
//  failures one at a time; the main window and each torn window carry this alert, and
//  ErrorWindowClaim (on the torn-window registry, shared by every window) decides which one
//  shows the current error: the window key when it arrived, or the first to become key
//  while it waits. A refusal from a torn window's inspector shows in that window, never twice.
//

import SwiftUI
import AppKit
import MachmanDesktopCore

struct WindowErrorAlert: ViewModifier {
	@ObservedObject var viewModel: VMListViewModel
	let window: CommandWindow
	@State private var isKey = false
	// The error this window holds, until its alert is dismissed.
	@State private var shown: UUID?

	func body(content: Content) -> some View {
		content
			.background(KeyWindowWatcher { key in
				isKey = key
				claim()
			})
			.onChange(of: viewModel.presentedError?.id, initial: true) { claim() }
			.onDisappear {
				viewModel.tornTabs.errorClaim.release(window)
				shown = nil
			}
			.alert(
				viewModel.presentedError?.title ?? "Error", isPresented: presented,
				presenting: viewModel.presentedError
			) { _ in
				// Empty: SwiftUI supplies the default OK button.
			} message: { error in
				Text(error.message)
			}
	}

	private var presented: Binding<Bool> {
		Binding(
			get: { shown != nil && shown == viewModel.presentedError?.id },
			set: { showing in
				guard !showing, shown != nil else { return }
				shown = nil
				viewModel.tornTabs.errorClaim.release(window)
				viewModel.isErrorPresented = false
			})
	}

	private func claim() {
		let error = viewModel.presentedError?.id
		let mine = viewModel.tornTabs.errorClaim.claims(
			error, for: window, isKey: isKey, anyWindowKey: NSApp.keyWindow != nil)
		shown = mine ? error : nil
	}
}

// Tells its view whether the window holding it is key, now and at every change. Takes no
// part in layout or hit testing (WindowCloseWatcher's shape).
private struct KeyWindowWatcher: NSViewRepresentable {
	let changed: (Bool) -> Void

	func makeNSView(context: Context) -> WatcherView {
		let view = WatcherView()
		view.changed = changed
		return view
	}

	func updateNSView(_ view: WatcherView, context: Context) {
		view.changed = changed
	}

	static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
		view.stopWatching()
	}

	final class WatcherView: NSView {
		var changed: ((Bool) -> Void)?
		private var observers: [NSObjectProtocol] = []

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			stopWatching()
			guard let window else { return }
			for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
				observers.append(NotificationCenter.default.addObserver(
					forName: name, object: window, queue: .main
				) { [weak self] _ in
					MainActor.assumeIsolated { self?.report() }
				})
			}
			// Not inside the view update that moved this view.
			DispatchQueue.main.async { [weak self] in self?.report() }
		}

		private func report() {
			changed?(window?.isKeyWindow ?? false)
		}

		func stopWatching() {
			observers.forEach(NotificationCenter.default.removeObserver)
			observers = []
		}
	}
}
