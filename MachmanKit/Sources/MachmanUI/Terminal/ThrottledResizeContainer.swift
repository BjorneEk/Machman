//
//  ThrottledResizeContainer.swift
//  MachmanUI
//
//  The view a terminal tab mounts its one persistent terminal view in. Every size change makes
//  SwiftTerm resize + reflow its ENTIRE populated scrollback (Buffer.resize iterates
//  lines.count, then reflowWider/Narrower rewraps), so following every frame of a window drag,
//  a canvas divider drag, a sidebar drag or the inspector's animation stalls the whole app. The
//  container therefore resizes its child itself, never through autoresizing: a change after a
//  calm applies at once (a tab switch, a zoom, a new window), and a burst of changes applies at
//  a bounded cadence with one exact snap once it settles. Plain AppKit, nothing
//  SwiftTerm-specific: any child view is throttled alike.
//

import AppKit

// Seconds on a monotonic clock, and "run this on the main thread that much later": real time in
// the app, a hand-driven clock in tests.
struct ResizeClock {
	var now: () -> TimeInterval
	var after: (TimeInterval, @escaping () -> Void) -> Void

	static let live = ResizeClock(
		now: { ProcessInfo.processInfo.systemUptime },
		after: { delay, body in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { body() } })
}

public final class ThrottledResizeContainer: NSView {
	// A change this long after the previous one starts afresh and applies at once; it is also
	// how long a burst must stay calm before the trailing snap.
	static let calm: TimeInterval = 0.15
	// Inside a burst: at most one apply per interval — or per costFactor × what the last apply
	// took, if that is longer. The cost is measured, not assumed: a deep scrollback or a slow
	// Mac spaces itself out instead of holding the main thread.
	static let interval: TimeInterval = 0.1
	static let costFactor = 4.0

	private weak var child: NSView?
	var clock = ResizeClock.live
	private var lastChange: TimeInterval?
	private var lastApplyEnd = -TimeInterval.infinity
	private var lastApplyCost: TimeInterval = 0
	private var snapArmed = false

	public override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configure()
	}

	public required init?(coder: NSCoder) {
		super.init(coder: coder)
		configure()
	}

	// AppKit must not resize the child along with the container: that is what kept the
	// throttle from ever running (P30). While the child lags it stays pinned top-left,
	// clipped (subviews draw outside their parent otherwise, over a divider or the next pane),
	// with the terminal's own background behind any uncovered strip.
	private func configure() {
		autoresizesSubviews = false
		clipsToBounds = true
		wantsLayer = true
	}

	public override var isFlipped: Bool { true }

	// Re-parents the terminal here. The explicit removeFromSuperview (rather than relying on
	// addSubview's implicit move) and the immediate frame are belt and braces for the
	// tab-to-window move: the new container may be sized after the fact, and a terminal left
	// at 0×0 is indistinguishable from "gone".
	public func adopt(_ view: NSView) {
		if view.superview !== self {
			view.removeFromSuperview()
			addSubview(view)
		}
		child = view
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

	// Every size change, whoever makes it (window, split view, SwiftUI animation), lands here.
	public override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		sizeChanged()
	}

	// A child left mismatched with nothing pending (sized before it was adopted) is fixed now.
	public override func layout() {
		super.layout()
		guard !snapArmed, let child, child.frame.size != bounds.size else { return }
		apply()
	}

	public override func viewDidEndLiveResize() {
		super.viewDidEndLiveResize()
		if let child, child.frame.size != bounds.size { apply() }
	}

	private func sizeChanged() {
		guard let child, child.frame.size != bounds.size else { return }
		let now = clock.now()
		let inBurst = lastChange.map { now - $0 < Self.calm } ?? false
		lastChange = now
		let spacing = max(Self.interval, Self.costFactor * lastApplyCost)
		if !inBurst || now - lastApplyEnd >= spacing {
			apply()
		} else {
			layer?.backgroundColor = child.layer?.backgroundColor
			armSnap(after: Self.calm)
		}
	}

	private func apply() {
		guard let child else { return }
		let start = clock.now()
		child.frame = bounds   // the terminal resizes and reflows right here
		lastApplyEnd = clock.now()
		lastApplyCost = lastApplyEnd - start
	}

	// One pending snap at a time; while changes keep coming it re-arms for the rest of the calm.
	private func armSnap(after delay: TimeInterval) {
		guard !snapArmed else { return }
		snapArmed = true
		clock.after(delay) { [weak self] in self?.snapIfCalm() }
	}

	private func snapIfCalm() {
		snapArmed = false
		let left = (lastChange ?? 0) + Self.calm - clock.now()
		if left > 0 {
			armSnap(after: left)
		} else if let child, child.frame.size != bounds.size {
			apply()
		}
	}
}
