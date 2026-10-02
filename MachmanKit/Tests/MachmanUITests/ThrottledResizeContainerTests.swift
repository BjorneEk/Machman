//
//  ThrottledResizeContainerTests.swift
//  MachmanUITests
//
//  The terminal's resize throttle, on plain NSViews and never in a window: the child is the
//  terminal stand-in, and a hand-driven clock replaces real time. P30: AppKit's autoresizing
//  resized the child on every frame, so the throttle never ran. P33: the throttle was keyed on
//  a window's live resize, so divider drags and animations went unthrottled.
//

import Testing
import AppKit
@testable import MachmanUI

@MainActor
struct ThrottledResizeContainerTests {
	// Counts its resizes; `cost` is what each one takes on the fake clock.
	final class Terminal: NSView {
		var resizes = 0
		var onResize: () -> Void = {}
		override func setFrameSize(_ newSize: NSSize) {
			super.setFrameSize(newSize)
			resizes += 1
			onResize()
		}
	}

	final class FakeClock {
		var now: TimeInterval = 100
		private var timers: [(at: TimeInterval, body: () -> Void)] = []

		// Holds the fake strongly: a container may outlive the test's own reference.
		var clock: ResizeClock {
			ResizeClock(
				now: { self.now },
				after: { delay, body in self.timers.append((self.now + delay, body)) })
		}

		// Moves time forward, running every timer that falls due on the way, in order.
		func advance(by seconds: TimeInterval) {
			let end = now + seconds
			while let next = timers.indices.filter({ timers[$0].at <= end })
				.min(by: { timers[$0].at < timers[$1].at }) {
				let timer = timers.remove(at: next)
				now = max(now, timer.at)
				timer.body()
			}
			now = end
		}
	}

	private let start = NSSize(width: 800, height: 480)

	private func mount(clock: FakeClock? = nil) -> (ThrottledResizeContainer, Terminal) {
		let container = ThrottledResizeContainer(frame: NSRect(origin: .zero, size: start))
		if let clock { container.clock = clock.clock }
		let child = Terminal(frame: .zero)
		container.adopt(child)
		child.resizes = 0
		return (container, child)
	}

	@Test func adoptingSizesTheTerminalAtOnce() {
		let container = ThrottledResizeContainer(frame: NSRect(origin: .zero, size: start))
		let child = Terminal(frame: .zero)
		container.adopt(child)
		#expect(child.frame.size == start)
	}

	@Test func aSingleChangeAppliesAtOnce() {
		let clock = FakeClock()
		let (container, child) = mount(clock: clock)
		container.setFrameSize(NSSize(width: 900, height: 500))
		#expect(child.frame.size == NSSize(width: 900, height: 500))
	}

	// Real time: two changes a moment apart. Under the autoresizing mask the second resized the
	// terminal at once too.
	@Test func aQuickSecondChangeWaits() {
		let (container, child) = mount()
		container.setFrameSize(NSSize(width: 900, height: 480))
		container.setFrameSize(NSSize(width: 910, height: 480))
		#expect(child.frame.size == NSSize(width: 900, height: 480))
	}

	@Test func aBurstHoldsTheTerminalUntilTheThrottleFires() {
		let clock = FakeClock()
		let (container, child) = mount(clock: clock)
		container.setFrameSize(NSSize(width: 820, height: 480))
		clock.advance(by: 0.02)
		container.setFrameSize(NSSize(width: 840, height: 480))
		#expect(child.frame.width == 820)
		clock.advance(by: 0.1)
		#expect(child.frame.width == 820)   // still inside the calm: no snap yet
		clock.advance(by: 0.06)
		#expect(child.frame.width == 840)
		#expect(child.resizes == 2)
	}

	// The reviewers' probe: a second of window drag at 60 frames a second.
	@Test func aDragOfSixtyFramesResizesTheTerminalAboutTenTimes() {
		let clock = FakeClock()
		let (container, child) = mount(clock: clock)
		var lagged = 0
		for frame in 1...60 {
			clock.advance(by: 1.0 / 60)
			container.setFrameSize(NSSize(width: 800 + 5 * Double(frame), height: 480))
			if child.frame.size != container.bounds.size { lagged += 1 }
		}
		clock.advance(by: 0.2)
		#expect(child.frame.size == container.bounds.size)
		#expect((8...11).contains(child.resizes), "resized \(child.resizes) times")
		#expect(lagged > 40)
	}

	// An apply that costs 50 ms holds the next one off for 200 ms, not 100.
	@Test func aCostlyResizeSpacesTheNextOneOut() {
		let clock = FakeClock()
		let (container, child) = mount(clock: clock)
		child.onResize = { clock.now += 0.05 }
		container.setFrameSize(NSSize(width: 820, height: 480))   // applies, ends at +0.05
		for _ in 0..<9 {
			clock.advance(by: 0.016)
			container.setFrameSize(NSSize(width: child.frame.width + 10, height: 480))
		}
		#expect(child.resizes == 1)   // 0.144 s after the first apply ended: under 0.2 s
		for _ in 0..<4 {
			clock.advance(by: 0.016)
			container.setFrameSize(NSSize(width: container.frame.width + 10, height: 480))
		}
		#expect(child.resizes == 2)
	}

	@Test func theEndOfALiveResizeSnapsAtOnce() {
		let clock = FakeClock()
		let (container, child) = mount(clock: clock)
		container.setFrameSize(NSSize(width: 820, height: 480))
		clock.advance(by: 0.01)
		container.setFrameSize(NSSize(width: 860, height: 480))
		#expect(child.frame.width == 820)
		container.viewDidEndLiveResize()
		#expect(child.frame.width == 860)
	}

	// A terminal knocked out of size with nothing pending is put right by the next layout.
	@Test func layoutFixesAMismatchNothingWillSnap() {
		let (container, child) = mount(clock: FakeClock())
		child.frame = .zero
		container.layout()
		#expect(child.frame.size == start)
	}

	@Test func aLaggingTerminalStaysTopLeftAndClipped() {
		let clock = FakeClock()
		let (container, child) = mount(clock: clock)
		container.setFrameSize(NSSize(width: 820, height: 480))
		clock.advance(by: 0.01)
		container.setFrameSize(NSSize(width: 600, height: 300))
		#expect(container.isFlipped)
		#expect(container.clipsToBounds)
		#expect(child.frame.origin == .zero)
		#expect(child.frame.size == NSSize(width: 820, height: 480))
	}
}
