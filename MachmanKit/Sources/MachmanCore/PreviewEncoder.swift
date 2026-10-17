//
//  PreviewEncoder.swift
//  MachmanCore
//
//  A VM window's preview frame as JPEG (E68): scaled with Core Graphics and encoded with
//  ImageIO, on no actor. LocalMachman runs it detached, so the vmhost's main actor — which
//  drives the VM window and answers the agent's socket — never draws or encodes a frame.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum PreviewEncoder {
	// No frame to capture (no window, no permission, a test suite): a black one this size.
	static let blankWidth = 300
	static let blankHeight = 200

	// The frame at most `maxWidth` pixels wide, keeping its aspect, as a JPEG at 0.7.
	static func jpeg(from frame: CGImage?, maxWidth: Int?) -> Data? {
		guard let source = frame ?? blankFrame() else { return nil }
		let image = maxWidth.flatMap { scaled(source, toWidth: $0) } ?? source
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(
			data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(
			destination, image,
			[kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return data as Data
	}

	// nil when the frame is already narrow enough.
	private static func scaled(_ image: CGImage, toWidth width: Int) -> CGImage? {
		guard width > 0, image.width > width else { return nil }
		let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width))
			.rounded()))
		guard let context = bitmap(width: width, height: height) else { return nil }
		context.interpolationQuality = .high
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return context.makeImage()
	}

	private static func blankFrame() -> CGImage? {
		guard let context = bitmap(width: blankWidth, height: blankHeight) else { return nil }
		context.setFillColor(CGColor(gray: 0, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: blankWidth, height: blankHeight))
		return context.makeImage()
	}

	private static func bitmap(width: Int, height: Int) -> CGContext? {
		guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
		return CGContext(
			data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
	}
}
