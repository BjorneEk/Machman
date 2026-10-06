//
//  RenderPasteboardLintTests.swift
//  MachmanAPITests
//
//  Q21: the device tree's Paste items read a pasteboard watch, and VMNavigationView and
//  VMDeviceTreeView fall back to the app's watch over the general pasteboard. The render tool
//  is no test-mode process, so a window scene built on that fallback read the user's real
//  pasteboard. Every scene that builds either view passes the scene's inert watch.
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct RenderPasteboardLintTests {
	@Test("Q21: no render scene builds the tree on the general pasteboard")
	func scenesPassTheirOwnPasteboard() throws {
		let files = RepoFiles.files(under: ["MachmanKit/Tools/MachmanRender"], extension: "swift")
		var calls = 0
		var bare: [String] = []
		for file in files {
			let text = try String(contentsOf: file, encoding: .utf8)
			let path = RepoFiles.relativePath(file)
			for view in ["VMNavigationView(", "VMDeviceTreeView("] {
				for arguments in Self.arguments(of: view, in: text) {
					calls += 1
					if !arguments.contains("pasteboard:") {
						bare.append("\(path): \(view)\(arguments.prefix(60))…")
					}
				}
			}
		}
		#expect(calls >= 6, "the scan found only \(calls) calls")
		#expect(bare.isEmpty, "\(bare.joined(separator: "\n"))")
	}

	// The text between each `call` and its matching close paren.
	static func arguments(of call: String, in text: String) -> [String] {
		var found: [String] = []
		var search = text.startIndex
		while let start = text.range(of: call, range: search..<text.endIndex) {
			var depth = 1
			var index = start.upperBound
			while index < text.endIndex, depth > 0 {
				if text[index] == "(" { depth += 1 }
				if text[index] == ")" { depth -= 1 }
				index = text.index(after: index)
			}
			found.append(String(text[start.upperBound..<index]))
			search = index
		}
		return found
	}
}
