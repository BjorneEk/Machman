//
//  ThrottledResizeContainer.swift
//  MachmanUI
//
//  The view a terminal tab mounts its one persistent terminal view in. Every size change makes
//  SwiftTerm resize + reflow its ENTIRE populated scrollback (Buffer.resize iterates
//  lines.count, then reflowWider/Narrower rewraps), so per-frame resizing during a window drag
//  stalls the whole app. The container feeds the terminal a new size at a bounded cadence while
//  the drag is live and snaps it exact when the drag ends; outside live resize it tracks
//  immediately. Plain AppKit, nothing SwiftTerm-specific: any child view is throttled alike.
//

import AppKit

public final class ThrottledResizeContainer: NSView {
	private static let interval: TimeInterval = 0.15
	private weak var child: NSView?
	private var pendingApply = false
	private var lastApply = Date.distantPast

	// Re-parents the terminal here. The explicit removeFromSuperview (rather than relying
	// on addSubview's implicit move) and the autoresizing mask are belt and braces for the
	// tab-to-window move: the new container is sized after the fact, and a terminal that
	// missed a layout pass would sit at 0×0 — indistinguishable from "gone".
	public func adopt(_ view: NSView) {
		if view.superview !== self {
			view.removeFromSuperview()
			addSubview(view)
		}
		child = view
		view.autoresizingMask = [.width, .height]
		if view.frame.size != bounds.size {
			view.frame = bounds
		}
	}

	// Called when this mount goes away. Only the container that still HOLDS the terminal
	// releases it; one that already lost it to another mount must not touch it.
	public func releaseChildIfOwned() {
		guard let held = child, held.superview === self else { return }
		held.removeFromSuperview()
		child = nil
	}

	public override func layout() {
		super.layout()
		guard let child, child.frame.size != bounds.size else { return }
		if inLiveResize {
			throttledApply()
		} else {
			child.frame = bounds
		}
	}

	private func throttledApply() {
		if Date().timeIntervalSince(lastApply) >= Self.interval {
			apply()
		} else if !pendingApply {
			pendingApply = true
			DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval) { [weak self] in
				guard let self else { return }
				self.pendingApply = false
				self.apply()
			}
		}
	}

	private func apply() {
		lastApply = Date()
		child?.frame = bounds
	}

	public override func viewDidEndLiveResize() {
		super.viewDidEndLiveResize()
		child?.frame = bounds
	}
}
