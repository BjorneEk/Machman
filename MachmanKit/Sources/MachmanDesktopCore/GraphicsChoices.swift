//
//  GraphicsChoices.swift
//  MachmanDesktopCore
//
//  What the display inspector's pickers offer. Resolution presets are keyed by both
//  dimensions (2560 × 1440 and 2560 × 1600 share a width — H14); the capture picker gains a
//  row for a mode a newer Machman set, so its selection is never blank (A15).
//

import MachmanAPI

public struct DisplayResolutionPreset: Hashable, Identifiable, Sendable {
	public let width: Int
	public let height: Int
	public var id: String { "\(width)x\(height)" }

	public init(width: Int, height: Int) {
		self.width = width
		self.height = height
	}
}

public enum GraphicsChoices {
	// The fixed presets, in picker order after the host display.
	public static let commonResolutions: [DisplayResolutionPreset] = [
		DisplayResolutionPreset(width: 1280, height: 800),
		DisplayResolutionPreset(width: 1920, height: 1080),
		DisplayResolutionPreset(width: 2560, height: 1440),
		DisplayResolutionPreset(width: 2560, height: 1600),
		DisplayResolutionPreset(width: 3024, height: 1964),
		DisplayResolutionPreset(width: 3456, height: 2234),
		DisplayResolutionPreset(width: 3840, height: 2160),
	]

	// The host display first (when the daemon reports one), then every common preset it does
	// not duplicate.
	public static func resolutionPresets(
		hostWidth: Int?, hostHeight: Int?
	) -> [DisplayResolutionPreset] {
		var presets: [DisplayResolutionPreset] = []
		if let hostWidth, let hostHeight {
			presets.append(DisplayResolutionPreset(width: hostWidth, height: hostHeight))
		}
		for preset in commonResolutions where !presets.contains(preset) {
			presets.append(preset)
		}
		return presets
	}

	// The capture picker's rows: the three modes, plus .unknown while the device holds a mode
	// this build can't name (picking a known row replaces it).
	public static func captureModes(current: SystemKeyCapture?) -> [SystemKeyCapture] {
		let known: [SystemKeyCapture] = [.off, .always, .fullScreen]
		return current == .unknown ? known + [.unknown] : known
	}
}
