//
//  ProgressCardBarTests.swift
//  MachmanTests
//
//  F9: a card that finished without ever reporting a fraction (a refused qcow2 import, a
//  failed kernel import or Rosetta install) kept spinning under its outcome for its whole
//  linger. A finished card's bar holds still; only running work without a fraction spins.
//

import Testing
import MachmanUI

struct ProgressCardBarTests {
	private func card(fraction: Double?, finished: Bool) -> ProgressCardModel {
		ProgressCardModel(
			id: "op", title: "Debian — Import disk", symbol: "", phase: "",
			fraction: fraction, finished: finished)
	}

	@Test func aFinishedCardWithoutAFractionHoldsStill() {
		#expect(card(fraction: nil, finished: true).barValue == 0)
	}

	@Test func aFractionShowsAsIs() {
		#expect(card(fraction: 0.4, finished: false).barValue == 0.4)
		#expect(card(fraction: 0.4, finished: true).barValue == 0.4)   // a cancel mid-way
		#expect(card(fraction: 1, finished: true).barValue == 1)       // done
	}

	@Test func runningWorkWithoutAFractionSpins() {
		#expect(card(fraction: nil, finished: false).barValue == nil)
	}
}
