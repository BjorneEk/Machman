//
//  Probes.swift
//  hostwatch
//
//  Helpers for lab.sh --self-check: a window that breaches the contract (safely), and a
//  unified-log line. Neither runs in a normal lab run.
//

import AppKit
import Foundation
import os

/// `window-probe --seconds N [--ordered S]`: ONE 1x1 borderless window at (-30000,-30000)
/// under .accessory, never key and never active, ordered front for `S` seconds (default
/// 1.2) of the N the process lives.
func runWindowProbe(_ args: [String]) {
	let seconds = Double(value("--seconds", in: args) ?? "4") ?? 4
	let ordered = Double(value("--ordered", in: args) ?? "1.2") ?? 1.2
	let app = NSApplication.shared
	app.setActivationPolicy(.accessory)
	let window = NSWindow(
		contentRect: NSRect(x: -30000, y: -30000, width: 1, height: 1),
		styleMask: [.borderless], backing: .buffered, defer: false)
	window.isReleasedWhenClosed = false
	window.ignoresMouseEvents = true
	window.hasShadow = false
	window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
	window.orderFrontRegardless()
	RunLoop.main.run(until: Date(timeIntervalSinceNow: min(ordered, seconds)))
	window.orderOut(nil)
	if seconds > ordered {
		RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds - ordered))
	}
	exit(0)
}

/// `logprobe --suite S --text TEXT`: one public line in subsystem S.
func runLogProbe(_ args: [String]) {
	guard let suite = value("--suite", in: args), let text = value("--text", in: args) else {
		exit(64)
	}
	Logger(subsystem: suite, category: "lab").log("\(text, privacy: .public)")
	exit(0)
}
