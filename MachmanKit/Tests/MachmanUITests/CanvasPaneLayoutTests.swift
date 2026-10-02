import Testing
import Foundation
import CoreGraphics
import MachmanUI

// Canvas pane widths (L2): each pane was max(120, available × fraction), so three panes with
// one divider dragged to its limit summed past the canvas and the trailing pane slid under
// the inspector. The panes plus dividers now always sum to the canvas width.
struct CanvasPaneLayoutTests {
	private let divider: CGFloat = 9

	private func sum(_ widths: [CGFloat]) -> CGFloat { widths.reduce(0, +) }

	private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

	@Test func onePaneTakesItAll() {
		#expect(CanvasPaneLayout.widths(fractions: [1.0], total: 500, divider: divider) == [500])
	}

	// The render scene's layout at 900 pt with the inspector open: 621 pt of canvas.
	@Test func threePanesNeverExceedTheCanvas() {
		let widths = CanvasPaneLayout.widths(
			fractions: [0.517, 0.15, 0.333], total: 621, divider: divider)
		#expect(close(sum(widths), 603))
		#expect(widths.allSatisfy { $0 >= 120 })
		// The old rule, for the record: it overflowed by about 30 pt here.
		let old = [0.517, 0.15, 0.333].map { max(120, 603 * CGFloat($0)) }
		#expect(sum(old) > 603)
	}

	@Test func corruptFractionsStillFit() {
		let doubled = CanvasPaneLayout.widths(fractions: [0.9, 0.9], total: 1000, divider: divider)
		#expect(close(sum(doubled), 991))
		#expect(close(doubled[0], doubled[1]))
		let junk = CanvasPaneLayout.widths(fractions: [-1, .nan, 1], total: 1000, divider: divider)
		#expect(close(sum(junk), 982))
		#expect(junk.allSatisfy { $0 >= 120 })
		let zeros = CanvasPaneLayout.widths(fractions: [0, 0], total: 409, divider: divider)
		#expect(zeros == [200, 200])
	}

	@Test func tooNarrowForTheMinimumSharesEqually() {
		let widths = CanvasPaneLayout.widths(
			fractions: [0.6, 0.3, 0.1], total: 200, divider: divider)
		#expect(widths.allSatisfy { close($0, 182.0 / 3) })
	}

	@Test func dividersWiderThanTheCanvas() {
		#expect(CanvasPaneLayout.widths(
			fractions: [0.5, 0.25, 0.25], total: 10, divider: divider) == [0, 0, 0])
		#expect(CanvasPaneLayout.widths(fractions: [], total: 500, divider: divider).isEmpty)
	}

	// Fractions that fit are drawn as stored: a plain split keeps its proportions.
	@Test func roomyFractionsKeepTheirProportions() {
		let widths = CanvasPaneLayout.widths(
			fractions: [0.25, 0.75], total: 1009, divider: divider)
		#expect(close(widths[0], 250) && close(widths[1], 750))
	}
}
