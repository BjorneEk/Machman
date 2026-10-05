//
//  OffscreenHost.swift
//  MachmanTestSupport
//
//  Hosts a SwiftUI view inside the test process with no way to reach the screen, so a test
//  can lay it out and read it (AXSnapshot) — never a window on screen, a Dock icon, focus or
//  a modal. Three tripwires, each failing the test that trips it:
//
//  - HostQuietApplication is the process's NSApp. It swallows modals, activation, attention
//    requests and every activation policy but .prohibited, recording each as a breach: a
//    product path that reaches NSApp.activate or runModal under a hosted view is reported,
//    never shown, and never hangs the run.
//  - HostWindow cannot be ordered: ordering it front, making it key, showing a sheet on it or
//    adding a child window records a breach and does nothing.
//  - HostQuiet checks the process after every hosted body: no visible or on-screen window,
//    not active, policy .prohibited, the standard defaults domain unchanged.
//
//  One hosted window at a time per process (the gate), so a breach names the right test.
//  The render tool's Offscreen (Tools/MachmanRender/Offscreen.swift) is the reference for the
//  hosting itself; it can't be shared, because this target links MachmanTestGuard, which
//  refuses the render suite. Unlike it, settling never runs the run loop by hand: the test
//  process's main run loop is live, and a Task.sleep hands it the turns SwiftUI needs.
//

import AppKit
import SwiftUI

// The tripwire NSApp: what would reach the user is recorded and dropped.
public final class HostQuietApplication: NSApplication {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var recorded: [String] = []

	static func record(_ breach: String) {
		lock.withLock { recorded.append(breach) }
	}

	// The breaches recorded since the last take, oldest first; the list starts over.
	public static func takeBreaches() -> [String] {
		lock.withLock {
			defer { recorded = [] }
			return recorded
		}
	}

	public override func runModal(for window: NSWindow) -> NSApplication.ModalResponse {
		Self.record("NSApp.runModal(for:) was called (a modal would have shown)")
		return .cancel
	}

	public override func activate(ignoringOtherApps flag: Bool) {
		Self.record("NSApp.activate(ignoringOtherApps:) was called")
	}

	public override func activate() {
		Self.record("NSApp.activate() was called")
	}

	public override func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
		guard policy == .prohibited else {
			Self.record("NSApp.setActivationPolicy(\(policy.spoken)) was called")
			return false
		}
		return super.setActivationPolicy(policy)   // host-quiet: .prohibited only
	}

	public override func requestUserAttention(
		_ requestType: NSApplication.RequestUserAttentionType
	) -> Int {
		Self.record("NSApp.requestUserAttention(_:) was called")
		return 0
	}
}

// A window that can't be ordered on screen: every way onto it records a breach instead.
// Ordering OUT still works, so close() does.
public final class HostWindow: NSWindow {
	public private(set) var breaches: [String] = []

	private func refuse(_ call: String) {
		breaches.append("the hosted window was asked to \(call)")
	}

	public override func orderFront(_ sender: Any?) { refuse("orderFront(_:)") }
	public override func makeKeyAndOrderFront(_ sender: Any?) {
		refuse("makeKeyAndOrderFront(_:)")
	}
	public override func orderFrontRegardless() { refuse("orderFrontRegardless()") }
	public override func makeKey() { refuse("makeKey()") }
	public override func makeMain() { refuse("makeMain()") }

	public override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
		guard place == .out else {
			refuse("order(_:relativeTo:)")
			return
		}
		super.order(place, relativeTo: otherWin)
	}

	public override func setIsVisible(_ flag: Bool) {
		guard !flag else {
			refuse("setIsVisible(true)")
			return
		}
		super.setIsVisible(flag)
	}

	public override func beginSheet(
		_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
	) {
		refuse("beginSheet(_:completionHandler:)")
	}

	public override func beginCriticalSheet(
		_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
	) {
		refuse("beginCriticalSheet(_:completionHandler:)")
	}

	public override func addChildWindow(
		_ childWin: NSWindow, ordered place: NSWindow.OrderingMode
	) {
		refuse("addChildWindow(_:ordered:)")
	}
}

// A view hosted by OffscreenHost.withHost, valid inside its body only.
@MainActor
public final class HostedView {
	public let window: NSWindow
	public let host: NSView
	public let chrome: OffscreenHost.Chrome

	init(window: NSWindow, host: NSView, chrome: OffscreenHost.Chrome) {
		self.window = window
		self.host = host
		self.chrome = chrome
	}

	public var bounds: CGRect { host.bounds }

	// Lay out, then give the main run loop a few turns: SwiftUI commits state changed in
	// onAppear and main-queue hops on later turns.
	public func settle(turns: Int = 6) async {
		await OffscreenHost.settle(host, turns: turns)
	}
}

@MainActor
public enum OffscreenHost {
	public enum Chrome: Sendable {
		case none       // borderless: the view alone
		case window     // titled + unified toolbar: the theme frame (and its toolbar) too
	}

	// The hosted body, or the host itself, reached the screen, the user or the defaults.
	public struct ReachedScreen: Error, CustomStringConvertible {
		public let breaches: [String]
		public var description: String {
			"the offscreen host reached the screen: " + breaches.joined(separator: "; ")
		}
	}

	// One hosted window (or tripwire test) at a time per process. Not reentrant: a body
	// running under it must not call withHost or exclusively again.
	private static let gate = AsyncGate(limit: 1)

	// Make HostQuietApplication the process's NSApp with the .prohibited policy (no Dock
	// icon, never active). Idempotent. An NSApp made before this (a plain NSApplication) has
	// no tripwire, which is itself a breach the next host reports.
	public static func prepare() {
		let existing: NSApplication? = NSApp
		if let existing, !(existing is HostQuietApplication) {
			HostQuietApplication.record(
				"NSApplication was created before OffscreenHost.prepare()")
			return
		}
		let app = HostQuietApplication.shared   // host-quiet: the tripwire app, made first
		if app.activationPolicy() != .prohibited {
			_ = app.setActivationPolicy(.prohibited)
		}
	}

	// `body` alone under the gate: for a test that pokes the app or a HostWindow directly,
	// so its breaches never mix with a hosted view's.
	public static func exclusively<T>(
		_ body: @MainActor () async throws -> T
	) async throws -> T {
		await gate.enter()
		do {
			prepare()
			let result = try await body()
			await gate.leave()
			return result
		} catch {
			await gate.leave()
			throw error
		}
	}

	// Host `view` (width/height nil: its fitting size on that axis), run `body` on it, take
	// it down, then throw ReachedScreen if anything reached the screen, the user or the
	// defaults meanwhile — the body's own result is dropped then.
	public static func withHost<V: View, T>(
		_ view: V, width: CGFloat? = nil, height: CGFloat? = nil, dark: Bool = false,
		chrome: Chrome = .none, _ body: @MainActor (HostedView) async throws -> T
	) async throws -> T {
		try await exclusively {
			_ = HostQuietApplication.takeBreaches()   // a stray earlier one is not ours
			let baseline = HostQuiet.baseline()
			let (window, host) = makeWindow(
				view, width: width, height: height, dark: dark, chrome: chrome)
			let hosted = HostedView(window: window, host: host, chrome: chrome)
			let outcome: Result<T, Error>
			do {
				try await fit(hosted, width: width, height: height)
				outcome = .success(try await body(hosted))
			} catch {
				outcome = .failure(error)
			}
			// Checked before the window goes: a sheet or child ordered with it is still there.
			var breaches = HostQuiet.breaches(since: baseline)
			window.contentView = nil
			window.close()
			breaches += HostQuietApplication.takeBreaches() + window.breaches
			guard breaches.isEmpty else { throw ReachedScreen(breaches: breaches) }
			return try outcome.get()
		}
	}

	private static func makeWindow<V: View>(
		_ view: V, width: CGFloat?, height: CGFloat?, dark: Bool, chrome: Chrome
	) -> (HostWindow, NSView) {
		// One instant per picture, as in the render tool: no animation phase to land on.
		let root = view
			.background(Color(nsColor: .windowBackgroundColor))
			.transaction {
				$0.disablesAnimations = true
				$0.animation = nil
			}
		let host = NSHostingView(rootView: root)
		let initial = NSRect(x: 0, y: 0, width: width ?? 1200, height: height ?? 2400)
		let style: NSWindow.StyleMask = chrome == .window
			? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
			: [.borderless]
		let window = HostWindow(
			contentRect: initial, styleMask: style, backing: .buffered, defer: true)
		window.isReleasedWhenClosed = false
		window.isRestorable = false
		window.animationBehavior = .none
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		if chrome == .window {
			window.toolbarStyle = .unified
			window.titlebarAppearsTransparent = false
		}
		window.contentView = host
		host.frame = initial
		return (window, host)
	}

	// Settle at the initial size, take the fitting size on the open axes, settle again.
	private static func fit(_ hosted: HostedView, width: CGFloat?, height: CGFloat?) async throws {
		await hosted.settle()
		let fitting = hosted.host.fittingSize
		let size = CGSize(
			width: width ?? max(fitting.width, 1), height: height ?? max(fitting.height, 1))
		hosted.window.setContentSize(size)
		hosted.host.frame = CGRect(origin: .zero, size: size)
		await hosted.settle()
	}

	static func settle(_ view: NSView, turns: Int) async {
		for _ in 0..<max(turns, 1) {
			view.layoutSubtreeIfNeeded()
			try? await Task.sleep(for: .milliseconds(20))
		}
		view.layoutSubtreeIfNeeded()
	}
}

extension NSApplication.ActivationPolicy {
	var spoken: String {
		switch self {
		case .regular: return ".regular"
		case .accessory: return ".accessory"
		case .prohibited: return ".prohibited"
		@unknown default: return "rawValue \(rawValue)"
		}
	}
}
