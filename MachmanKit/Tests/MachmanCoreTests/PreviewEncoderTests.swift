//
//  PreviewEncoderTests.swift
//  MachmanCoreTests
//
//  E68: vm.preview captured off the main actor, then scaled the frame by drawing into an
//  NSImage, round-tripped it through TIFF and encoded the JPEG on the vmhost's main actor —
//  the actor that drives the VM window and answers the agent. The encoder works from the
//  captured CGImage now, with Core Graphics and ImageIO, on no actor.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MachmanCore

struct PreviewEncoderTests {
	// A frame whose top half is red and bottom half blue, `width` × `height` pixels.
	private func frame(width: Int, height: Int) throws -> CGImage {
		let context = try #require(CGContext(
			data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
		context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))   // y up: bottom
		context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
		context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
		return try #require(context.makeImage())
	}

	// The decoded JPEG's size and the colour at the middle of its top and bottom rows.
	private func decode(_ data: Data) throws -> (width: Int, height: Int, top: Int, bottom: Int) {
		let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
		#expect(CGImageSourceGetType(source) as String? == "public.jpeg")
		let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
		var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
		let context = try #require(CGContext(
			data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
			bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		// Memory rows run top-down: row 2 is the top of the picture.
		func red(row: Int) -> Int { Int(pixels[(row * image.width + image.width / 2) * 4]) }
		return (image.width, image.height, red(row: 2), red(row: image.height - 3))
	}

	@Test("E68: the preview encoder scales a frame to the asked width and keeps it upright")
	func theEncoderScalesAndKeepsTheFrameUpright() async throws {
		let source = try frame(width: 2560, height: 1600)
		// Off the main actor, as LocalMachman runs it.
		let encoded = await Task.detached { PreviewEncoder.jpeg(from: source, maxWidth: 640) }
			.value
		let scaled = try decode(try #require(encoded))
		#expect(scaled.width == 640)
		#expect(scaled.height == 400)
		#expect(scaled.top > 200)      // red on top
		#expect(scaled.bottom < 60)    // blue below

		// Narrower than asked, or no width asked: the frame as it is.
		let whole = try decode(try #require(PreviewEncoder.jpeg(from: source, maxWidth: nil)))
		#expect(whole.width == 2560)
		#expect(try decode(try #require(PreviewEncoder.jpeg(from: source, maxWidth: 4000)))
			.width == 2560)
		// No frame: the black one, as before.
		let blank = try decode(try #require(PreviewEncoder.jpeg(from: nil, maxWidth: 640)))
		#expect(blank.width == 300)
		#expect(blank.height == 200)
		#expect(blank.top < 20)
	}

	@Test("E68: the vmhost's preview path does no AppKit drawing")
	func thePreviewPathDoesNoAppKitDrawing() throws {
		let file = "MachmanKit/Sources/MachmanCore/LocalMachman.swift"
		let found = try SourceScan.hits(
			#"lockFocus|tiffRepresentation|NSBitmapImageRep|NSImage\("#, in: [file])
		#expect(found.isEmpty, "encode with PreviewEncoder, off the main actor: \(found)")
	}
}
