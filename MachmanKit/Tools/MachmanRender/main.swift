//
//  main.swift
//  MachmanRender
//
//  Draws named scenes of the desktop's views to PNG — no window on screen, no Dock icon, no
//  focus, no daemon. Run it through scripts/render.sh, which builds it and hands it a
//  throwaway sandbox (suite id, data dir, fake home); outside one it refuses to start.
//

import AppKit

// Before anything can resolve a Machman path: an unbundled process would otherwise fall
// back to the RELEASE suite's library for every store that persists.
RenderSandbox.enforce()

// Prohibited: never a Dock icon, never a menu bar, can never become active. Set before any
// window exists; nothing below orders a window front, makes one key, or runs the app loop.
NSApplication.shared.setActivationPolicy(.prohibited)

let status = MainActor.assumeIsolated {
	RenderCommand.run(Array(CommandLine.arguments.dropFirst()))
}
exit(status)
