//
//  CopyLabelTests.swift
//  MachmanCoreTests
//
//  F8: a copy's progress card is titled "<target> — <label>", and the label repeated the
//  target ("Copying Alpine → Alpine copy"), so the 280 pt card cut off before the source.
//

import Testing
import Foundation
@testable import MachmanCore

@MainActor
struct CopyLabelTests {
	@Test func aCopysLabelNamesItsSource() {
		let label = LocalMachman.copyLabel(source: "Alpine")
		#expect(label == "Copying from Alpine")
		#expect(!label.contains("→"))
	}
}
