//
//  Scene.swift
//  MachmanRender
//
//  A named, reproducible picture of one desktop view: the widths it is drawn at, its height
//  (fixed or fitted), window chrome or none, and a builder that makes the view from a fresh
//  SceneContext (sample VMs over StubMachman). Scenes live in Scenes/<area>.swift and are
//  listed in SceneRegistry — adding one is one entry there, nothing else. A scene never
//  writes UserDefaults.standard or an @AppStorage key: that domain lives in the real home
//  and every run shares it (see RenderSandbox).
//

import SwiftUI
import MachmanAPI
import MachmanFixtures

struct RenderScene {
	// Standard sweeps (the UI-lane gate): inspectors and windows at these widths.
	static let inspectorWidths: [CGFloat] = [260, 320, 420]
	static let windowWidths: [CGFloat] = [900, 1200, 1600]

	let name: String            // "inspector.disk" — dotted, area first, globbable
	let summary: String
	var widths: [CGFloat?] = [nil]   // nil = the view's own fitting width
	var height: CGFloat? = nil       // nil = fitting height
	var chrome: Offscreen.Chrome = .none
	// The VMs the scene's StubMachman serves (Samples builders; default: the library).
	var vms: () -> [VMInfo] = Samples.library
	// Window scenes: the real column views painted over the window's glass panels, left
	// to right (see Offscreen.paintPanels).
	var panels: (@MainActor (SceneContext) -> [AnyView])? = nil
	let make: @MainActor (SceneContext) -> AnyView

	init(
		_ name: String, _ summary: String, widths: [CGFloat?] = [nil],
		height: CGFloat? = nil, chrome: Offscreen.Chrome = .none,
		vms: @escaping () -> [VMInfo] = Samples.library,
		panels: (@MainActor (SceneContext) -> [AnyView])? = nil,
		make: @escaping @MainActor (SceneContext) -> AnyView
	) {
		self.panels = panels
		self.vms = vms
		self.name = name
		self.summary = summary
		self.widths = widths
		self.height = height
		self.chrome = chrome
		self.make = make
	}
}
