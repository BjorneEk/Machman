//
//  MainWindowLayout.swift
//  MachmanDesktopUI
//
//  What each region of the connected main window needs at least (L1). SwiftUI derives the
//  window's minimum from them (the Window scene sizes by .contentMinSize): the sidebar
//  column's width plus the canvas's minimum, plus the inspector column while it shows, so
//  opening the inspector raises the floor and closing it lowers it. The column widths live
//  here so each number has one home.
//

import CoreGraphics

enum MainWindowLayout {
	struct Column {
		let min: CGFloat
		let ideal: CGFloat
		let max: CGFloat
	}

	// The tree needs room for entry names and badges; the system minimum is too tight.
	static let sidebar = Column(min: 230, ideal: 270, max: 420)
	static let inspector = Column(min: 250, ideal: 300, max: 380)
	// One canvas pane under its tab strip. At 300 × 300 a macOS install's phase row
	// ("Downloading macOS 26.0.1…" + Cancel) stays on one line above a 16:10 display block
	// that still holds a stopped VM's Start button and label, and the state caption below
	// it; at 280 pt the row wraps (renders, wave 3).
	static let canvas = CGSize(width: 300, height: 300)
}
