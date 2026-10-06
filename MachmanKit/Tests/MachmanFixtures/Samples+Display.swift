//
//  Samples+Display.swift
//  MachmanFixtures
//
//  Display-device states for the graphics inspector (lane 1e): a resolution that shares its
//  width with another preset, and a capture mode a newer Machman wrote.
//

import Foundation
import CoreGraphics
import ImageIO
import MachmanAPI

extension Samples {
	// H14: the Linux sample with its display fixed at width × height (2560 × 1600 shares its
	// width with the 2560 × 1440 preset).
	public static func linuxDisplay(
		_ name: String = "Debian", width: Int, height: Int, state: VMState = .stopped
	) -> VMInfo {
		var vm = linux(name, state: state)
		vm.devices = vm.devices?.map { device in
			guard device.kind == .graphics else { return device }
			var graphics = device
			graphics.displayWidthPixels = width
			graphics.displayHeightPixels = height
			return graphics
		}
		return vm
	}

	// A15: the Linux sample whose display holds a capture mode a newer Machman wrote
	// ("whenFocused"): this build reads it as .unknown and sends it back verbatim.
	public static func linuxNewerCaptureMode(
		_ name: String = "Debian", state: VMState = .stopped
	) -> VMInfo {
		var vm = linux(name, state: state)
		vm.devices = vm.devices?.map { device in
			guard device.kind == .graphics else { return device }
			var graphics = device
			graphics.systemKeyCaptureSpelling = "whenFocused"
			return graphics
		}
		return vm
	}
}

extension Samples {
	// A preview frame the desktop can decode: a flat grey PNG of width × height (the stub's
	// default preview payload is three bytes that never decode).
	public static func previewPNG(width: Int = 64, height: Int = 40) -> Data {
		let context = CGContext(
			data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		context.setFillColor(CGColor(gray: 0.4, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		let data = NSMutableData()
		let destination = CGImageDestinationCreateWithData(
			data as CFMutableData, "public.png" as CFString, 1, nil)!
		CGImageDestinationAddImage(destination, context.makeImage()!, nil)
		CGImageDestinationFinalize(destination)
		return data as Data
	}
}
