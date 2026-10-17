import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Error alerts wait their turn: a second failure never replaces the one being shown (P15).
@MainActor
struct ErrorQueueTests {
	@Test func aSecondErrorWaitsForTheFirst() async {
		let h = await DesktopHarness.make()
		h.viewModel.present(message: "first", while: "Doing A")
		h.viewModel.present(message: "second", while: "Doing B")
		#expect(h.viewModel.presentedError?.message == "first")
		h.viewModel.isErrorPresented = false
		#expect(await eventually { h.viewModel.presentedError?.message == "second" })
		h.viewModel.isErrorPresented = false
		#expect(await eventually { h.viewModel.presentedError == nil })
	}

	@Test func aRepeatedErrorShowsOnce() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.present(message: "disk busy", while: "Removing a disk")
		h.viewModel.present(message: "disk busy", while: "Removing a disk")
		h.viewModel.present(message: "next", while: "Doing B")
		h.viewModel.isErrorPresented = false
		// The repeat never queued: the alert after the first is the other failure — an outcome
		// to wait for, not a fixed sleep past the re-present delay (Q34).
		#expect(await eventually { h.viewModel.presentedError?.message == "next" })
	}

	@Test func twoFailedStartsBothSurface() async {
		let h = await DesktopHarness.make()
		h.stub.fail("start", with: MachmanError(code: .invalidState, message: "a"))
		h.viewModel.startVM("Alpine")
		#expect(await eventually { h.viewModel.presentedError?.message == "a" })
		h.stub.fail("start", with: MachmanError(code: .invalidState, message: "b"))
		h.viewModel.startVM("Fedora")
		#expect(await eventually { h.stub.starts.isEmpty && !h.viewModel.isStartPending("Fedora") })
		#expect(h.viewModel.presentedError?.message == "a")
		h.viewModel.isErrorPresented = false
		#expect(await eventually { h.viewModel.presentedError?.message == "b" })
		#expect(h.viewModel.presentedError?.title == "Starting \u{201C}Fedora\u{201D} failed")
	}

	@Test func theQueueIsFirstInFirstOut() {
		var queue = PresentationQueue<String>()
		queue.enqueue("a")
		queue.enqueue("b")
		queue.enqueue("c")
		#expect(queue.current == "a")
		var more = queue.dismiss()
		#expect(more)
		#expect(queue.current == nil)
		queue.advance()
		#expect(queue.current == "b")
		more = queue.dismiss()
		#expect(more)
		queue.advance()
		#expect(queue.current == "c")
		more = queue.dismiss()
		#expect(!more)
		queue.advance()
		#expect(queue.current == nil)
	}

	@Test func anItemArrivingBetweenTwoWaitsBehindTheRest() {
		var queue = PresentationQueue<String>()
		queue.enqueue("a")
		queue.enqueue("b")
		let more = queue.dismiss()
		#expect(more)
		queue.enqueue("c")   // during the dismissal, before advance()
		queue.advance()
		#expect(queue.current == "b")
		#expect(queue.waiting == ["c"])
	}

	@Test func duplicatesOfShownOrWaitingItemsAreDropped() {
		var queue = PresentationQueue<String>()
		queue.enqueue("a", duplicate: ==)
		queue.enqueue("b", duplicate: ==)
		queue.enqueue("a", duplicate: ==)
		queue.enqueue("b", duplicate: ==)
		#expect(queue.current == "a")
		#expect(queue.waiting == ["b"])
		queue.enqueue("a")   // no duplicate rule: it queues
		#expect(queue.waiting == ["b", "a"])
	}
}
