import Testing
import Foundation
import MachmanAPI
import MachmanFixtures

// Samples are the expected values later view-model tests compare against, so two builds of the
// same sample must be equal within a run — now-relative dates included.
struct SamplesTests {
	@Test func buildersAreEqualWithinARun() {
		#expect(Samples.library() == Samples.library())
		#expect(Samples.copyOperation() == Samples.copyOperation())
	}

	@Test func nowRelativeDatesKeepTheirOffsets() throws {
		let lastRan = try #require(Samples.linux().lastRan)
		#expect(Samples.now.timeIntervalSince(lastRan) == 3_600)
		#expect(Samples.now.timeIntervalSince(Samples.copyOperation().startedAt) == 90)
	}
}
