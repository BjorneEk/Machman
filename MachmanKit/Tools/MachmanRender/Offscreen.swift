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
//  The window is deferred (never gets a window-server window at all) and never ordered.
//
//  Nothing here orders a window, makes one key, activates the app, or runs NSApp.
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

	// width/height nil = the view's fitting size on that axis.
	static func png(
		_ view: AnyView, width: CGFloat?, height: CGFloat?, dark: Bool,
		chrome: Chrome = .none, panels: [AnyView] = [], scale: CGFloat = 2
	) -> (data: Data, size: CGSize)? {
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
		if chrome == .window { hideToolbarGlass(in: target) }
		let bounds = target.bounds
		let pixelsWide = Int(bounds.width * scale), pixelsHigh = Int(bounds.height * scale)
		guard pixelsWide > 0, pixelsHigh > 0,
			let rep = NSBitmapImageRep(
				bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
				bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
				colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
		else {
			window.contentView = nil
			return nil
		}
		rep.size = bounds.size
		target.cacheDisplay(in: bounds, to: rep)
		redrawTerminals(in: target, into: rep)
		if !panels.isEmpty {
			paintPanels(panels, over: target, into: rep, dark: dark, scale: scale)
		}
		window.contentView = nil
		window.close()
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

	// Run the main run loop until `done` or the timeout (async work the scenes wait on).
	static func pump(until done: () -> Bool, timeout: TimeInterval = 5) {
		let deadline = Date().addingTimeInterval(timeout)
		while !done(), Date() < deadline {
			RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
		}
	}
}

extension Offscreen {
	// Toolbar item platters are small Liquid Glass views; cacheDisplay draws them as opaque
	// white pills (hiding dark-mode icons). The items themselves are separate views, so
	// hiding the platters leaves the items on the plain titlebar.
	static func hideToolbarGlass(in root: NSView) {
		guard let glassClass = NSClassFromString("NSGlassEffectView") else { return }
		func walk(_ v: NSView) {
			if v.isKind(of: glassClass), v.bounds.width <= 120 { v.isHidden = true; return }
			v.subviews.forEach(walk)
		}
		walk(root)
	}

	// macOS 26 draws a split view's sidebar and inspector as Liquid Glass panels, which
	// cacheDisplay cannot draw (and a never-shown window never mounts the sidebar's content).
	// Find the panels (NSGlassEffectView subclasses wider than a toolbar platter), left to
	// right, and paint the matching real column views — rendered on their own at exactly the
	// panel's size — into the window image. Glass becomes flat; layout stays the window's.
	static func paintPanels(
		_ panels: [AnyView], over root: NSView, into rep: NSBitmapImageRep, dark: Bool,
		scale: CGFloat
	) {
		guard let glassClass = NSClassFromString("NSGlassEffectView") else { return }
		var found: [NSView] = []
		func walk(_ v: NSView) {
			if v.isKind(of: glassClass), v.bounds.width > 120 { found.append(v); return }
			v.subviews.forEach(walk)
		}
		walk(root)
		let rects = found.map { $0.convert($0.bounds, to: root) }.sorted { $0.minX < $1.minX }
		guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = ctx
		for (rect, panel) in zip(rects, panels) {
			guard let drawn = png(
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
		NSGraphicsContext.restoreGraphicsState()
	}
}

extension Offscreen {
	// A SwiftTerm TerminalView clears its rect to transparent and keeps its background colour
	// in a layer property, which cacheDisplay never draws — so drawn with the rest of the
	// view tree its background is a hole, and its glyphs can go missing as well (in the light
	// scheme every one did). Drawn into a bitmap of its own it comes out whole: paint each
	// visible terminal back in at its place, over its layer's background colour.
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
			if let background = terminal.layer?.backgroundColor {
				ctx.cgContext.setFillColor(background)
				ctx.cgContext.fill(rect)
			}
			let image = NSImage(size: visible.size)
			image.addRepresentation(own)
			image.draw(in: rect)
		}
	}
}

// NSToolbarItemViewer is private; match it by class name.
private extension NSView {
	var isToolbarItemViewer: Bool { String(describing: type(of: self)) == "NSToolbarItemViewer" }
}
