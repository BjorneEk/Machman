//
//  Offscreen.swift
//  MachmanRender
//
//  Draws a SwiftUI view to PNG without showing it. The view is hosted in an NSHostingView
//  inside a window that is never ordered on screen, laid out, given a few run-loop turns to
//  settle (onAppear work, deferred main-queue hops), then drawn with cacheDisplay — so
//  AppKit-backed pieces (text fields, pickers, lists) draw as themselves. ImageRenderer
//  draws grouped Forms blank and AppKit controls as placeholders (lane 0b). SwiftTerm
//  terminals are drawn again on their own (see redrawTerminals).
//  The window is deferred and never ordered, so it never reaches the screen. The one
//  window-server window a run does own is TextInputUI's cursor helper (TUINSWindow), made
//  once per process by the first NSTextView (a TextEditor) and never ordered either.
//
//  Nothing here orders a window, makes one key, activates the app, or runs NSApp. png()
//  checks that before it closes its window, while the window and anything a scene ordered
//  with it (a sheet, a popover, a child window) still exist, and throws ReachedScreen if any
//  window of the process is visible or on screen, or the app is active; RenderCommand checks
//  again after every scene, for activation and for windows that outlive a scene.
//

import AppKit
import SwiftTerm
import SwiftUI

@MainActor
enum Offscreen {
	enum Chrome {
		case none       // borderless: the view alone (inspectors, popovers, sheets)
		case window     // titled + unified toolbar: the theme frame is drawn too
	}

	// A window of the process was visible or on screen, or the app was active: the run stops.
	struct ReachedScreen: Error {}

	// width/height nil = the view's fitting size on that axis; nil result = a failed render.
	static func png(
		_ view: AnyView, width: CGFloat?, height: CGFloat?, dark: Bool,
		chrome: Chrome = .none, panels: [AnyView] = [], scale: CGFloat = 2
	) throws -> (data: Data, size: CGSize)? {
		// Liquid Glass (glassEffect) never draws under cacheDisplay: its platter goes missing
		// and its adaptive foreground turns dark on dark. Reduce Transparency switches
		// MachmanGlassSurface to its opaque form, a surface the app really draws, so toasts,
		// cards and the VM indicator keep their true text and state colours.
		let root = view
			.environment(\._accessibilityReduceTransparency, true)
			.background(Color(nsColor: .windowBackgroundColor))
		let host = NSHostingView(rootView: root)
		let initial = NSRect(x: 0, y: 0, width: width ?? 1200, height: height ?? 2400)
		let style: NSWindow.StyleMask = chrome == .window
			? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
			: [.borderless]
		let window = NSWindow(
			contentRect: initial, styleMask: style, backing: .buffered, defer: true)
		window.isReleasedWhenClosed = false
		// Every return, early ones included, takes the view out and closes the window.
		defer {
			window.contentView = nil
			window.close()
		}
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		if chrome == .window {
			window.toolbarStyle = .unified
			window.titlebarAppearsTransparent = false
		}
		window.contentView = host
		host.frame = initial
		settle(host)

		let fitting = host.fittingSize
		let size = CGSize(
			width: width ?? max(fitting.width, 1), height: height ?? max(fitting.height, 1))
		window.setContentSize(size)
		host.frame = CGRect(origin: .zero, size: size)
		settle(host)

		// Window chrome lives in the theme frame, above the content view.
		let target: NSView = chrome == .window ? (host.superview ?? host) : host
		let drawn = try capture(target, chrome: chrome, panels: panels, dark: dark, scale: scale)
		// Before the deferred close: a window ordered for this scene is still there to see.
		if reachedScreen() { throw ReachedScreen() }
		return drawn
	}

	private static func capture(
		_ target: NSView, chrome: Chrome, panels: [AnyView], dark: Bool, scale: CGFloat
	) throws -> (data: Data, size: CGSize)? {
		if chrome == .window { hideToolbarGlass(in: target) }
		let bounds = target.bounds
		let pixelsWide = Int(bounds.width * scale), pixelsHigh = Int(bounds.height * scale)
		guard pixelsWide > 0, pixelsHigh > 0,
			let rep = NSBitmapImageRep(
				bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
				bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
				colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
		else { return nil }
		rep.size = bounds.size
		target.cacheDisplay(in: bounds, to: rep)
		redrawTerminals(in: target, into: rep)
		if !panels.isEmpty {
			try paintPanels(panels, over: target, into: rep, dark: dark, scale: scale)
		}
		guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
		return (data, bounds.size)
	}

	// Lay out, then let the main queue and run loop drain a few times: SwiftUI commits
	// state changed in onAppear (and DispatchQueue.main.async hops) on later turns.
	static func settle(_ view: NSView, turns: Int = 6) {
		for _ in 0..<turns {
			view.layoutSubtreeIfNeeded()
			RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
		}
		view.layoutSubtreeIfNeeded()
		view.displayIfNeeded()
	}

	// The standing proof: no window of this process visible (AppKit's view, which also sees a
	// sheet or popover the moment it is ordered) or on screen (the window server's), and the
	// app never active.
	static func reachedScreen() -> Bool {
		let pid = ProcessInfo.processInfo.processIdentifier
		let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
			as? [[String: Any]] ?? []
		return NSApp.isActive
			|| NSApp.windows.contains { $0.isVisible }
			|| onScreen.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
	}

	// Run the main run loop until `done` or the timeout (async work the scenes wait on).
	static func pump(until done: () -> Bool, timeout: TimeInterval = 5) {
		let deadline = Date().addingTimeInterval(timeout)
		while !done(), Date() < deadline {
			RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
		}
	}
}

extension Offscreen {
	// A split-view column's glass panel, as opposed to a toolbar item's platter: wider than a
	// platter and taller than the titlebar. Width alone failed once a status subtitle ("Not
	// responding") stretched the indicator's platter past 120 pt.
	static func isColumnGlass(_ v: NSView) -> Bool {
		v.bounds.width > 120 && v.bounds.height > 60
	}

	// Toolbar item platters are small Liquid Glass views; cacheDisplay draws them as opaque
	// white pills (hiding dark-mode icons). The items themselves are separate views, so
	// hiding the platters leaves the items on the plain titlebar.
	static func hideToolbarGlass(in root: NSView) {
		guard let glassClass = NSClassFromString("NSGlassEffectView") else { return }
		func walk(_ v: NSView) {
			if v.isKind(of: glassClass), !isColumnGlass(v) { v.isHidden = true; return }
			v.subviews.forEach(walk)
		}
		walk(root)
	}

	// macOS 26 draws a split view's sidebar and inspector as Liquid Glass panels, which
	// cacheDisplay cannot draw (and a never-shown window never mounts the sidebar's content).
	// Find the panels (NSGlassEffectView subclasses passing isColumnGlass), left to
	// right, and paint the matching real column views — rendered on their own at exactly the
	// panel's size — into the window image. Glass becomes flat; layout stays the window's.
	static func paintPanels(
		_ panels: [AnyView], over root: NSView, into rep: NSBitmapImageRep, dark: Bool,
		scale: CGFloat
	) throws {
		guard let glassClass = NSClassFromString("NSGlassEffectView") else { return }
		var found: [NSView] = []
		func walk(_ v: NSView) {
			if v.isKind(of: glassClass), isColumnGlass(v) { found.append(v); return }
			v.subviews.forEach(walk)
		}
		walk(root)
		let rects = found.map { $0.convert($0.bounds, to: root) }.sorted { $0.minX < $1.minX }
		guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = ctx
		defer { NSGraphicsContext.restoreGraphicsState() }
		for (rect, panel) in zip(rects, panels) {
			guard let drawn = try png(
				panel, width: rect.width, height: rect.height, dark: dark, scale: scale),
				let image = NSImage(data: drawn.data)
			else { continue }
			image.draw(in: rect)
		}
		// The toolbar items above the columns go back on top of the painted panels.
		var items: [NSView] = []
		func collect(_ v: NSView) {
			if v.isToolbarItemViewer { items.append(v); return }
			v.subviews.forEach(collect)
		}
		collect(root)
		for item in items where !item.isHidden && item.bounds.width > 0 {
			let rect = item.convert(item.bounds, to: root)
			guard let itemRep = item.bitmapImageRepForCachingDisplay(in: item.bounds) else {
				continue
			}
			item.cacheDisplay(in: item.bounds, to: itemRep)
			let image = NSImage(size: item.bounds.size)
			image.addRepresentation(itemRep)
			image.draw(in: rect)
		}
	}
}

extension Offscreen {
	// A SwiftTerm TerminalView clears its rect to transparent and keeps its background colour
	// in a layer property, which cacheDisplay never draws — so drawn with the rest of the
	// view tree its background is a hole, and its glyphs can go missing as well (in the light
	// scheme every one did). Drawn into a bitmap of its own it comes out whole. Each visible
	// terminal goes back in at its place UNDER what the tree drew (destination-over), then its
	// layer's background colour under that: they fill the hole only, so SwiftUI content laid
	// over a terminal (the SSH tab's "Session ended." banner) stays on top.
	static func redrawTerminals(in root: NSView, into rep: NSBitmapImageRep) {
		var found: [TerminalView] = []
		func walk(_ v: NSView) {
			if let terminal = v as? TerminalView { found.append(terminal); return }
			v.subviews.forEach(walk)
		}
		walk(root)
		guard !found.isEmpty, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = ctx
		defer { NSGraphicsContext.restoreGraphicsState() }
		for terminal in found where !terminal.isHiddenOrHasHiddenAncestor {
			let visible = terminal.visibleRect
			guard !visible.isEmpty,
				let own = terminal.bitmapImageRepForCachingDisplay(in: visible)
			else { continue }
			terminal.cacheDisplay(in: visible, to: own)
			var rect = terminal.convert(visible, to: root)
			// The bitmap's context is unflipped; a hosting view is flipped.
			if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
			let image = NSImage(size: visible.size)
			image.addRepresentation(own)
			image.draw(in: rect, from: .zero, operation: .destinationOver, fraction: 1)
			if let background = terminal.layer?.backgroundColor {
				let cg = ctx.cgContext
				cg.saveGState()
				cg.setBlendMode(.destinationOver)
				cg.setFillColor(background)
				cg.fill(rect)
				cg.restoreGState()
			}
		}
	}
}

// NSToolbarItemViewer is private; match it by class name.
private extension NSView {
	var isToolbarItemViewer: Bool { String(describing: type(of: self)) == "NSToolbarItemViewer" }
}
