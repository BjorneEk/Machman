//
//  GlyphColourTests.swift
//  MachmanDesktopUITests
//
//  W4-8 (H11): the agent menu's VM glyph draws green while the VM runs and adds a yellow
//  shield on a safe run; a stopped VM's glyph has no green. Read from pixels: StatusIcon
//  hosted offscreen and drawn into a bitmap by its own view (cacheDisplay) — no screen
//  capture, nothing on screen. A live NSMenu may flatten the colours to a template; that
//  stays a manual check.
//

import AppKit
import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanTestSupport

// L1: a view hosted offscreen and drawn into a bitmap in-process.
@MainActor
struct GlyphColourTests {
	struct Hues: CustomStringConvertible {
		var green = 0
		var yellow = 0
		var description: String { "green \(green), yellow \(yellow)" }
	}

	// Saturated, bright pixels by hue band: green 90–160°, yellow 40–65°.
	private func hues(_ icon: StatusIcon) async throws -> Hues {
		try await OffscreenHost.withHost(icon, width: 32, height: 32) { hosted in
			let view = hosted.host
			let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
			view.cacheDisplay(in: view.bounds, to: rep)
			var found = Hues()
			for x in 0..<rep.pixelsWide {
				for y in 0..<rep.pixelsHigh {
					guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
						color.saturationComponent > 0.4, color.brightnessComponent > 0.4,
						color.alphaComponent > 0.5
					else { continue }
					let hue = color.hueComponent * 360
					if (90...160).contains(hue) { found.green += 1 }
					if (40...65).contains(hue) { found.yellow += 1 }
				}
			}
			return found
		}
	}

	@Test("W4-8: the agent's running glyph draws green and a safe run's shield yellow")
	func runningIsGreenAndSafeIsYellow() async throws {
		let safe = try await hues(StatusIcon(state: .running, windowOpen: true, safeRun: true))
		#expect(safe.green > 0 && safe.yellow > 0, "safe run: \(safe)")
		let running = try await hues(StatusIcon(state: .running, windowOpen: false))
		#expect(running.green > 0 && running.yellow == 0, "running: \(running)")
		let stopped = try await hues(StatusIcon(state: .stopped, windowOpen: false))
		#expect(stopped.green == 0 && stopped.yellow == 0, "stopped: \(stopped)")
	}
}
