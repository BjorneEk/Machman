//
//  InspectorSymbolLintTests.swift
//  MachmanAPITests
//
//  One inspector never draws two of its icon buttons with one glyph (H59): a destructive
//  "Regenerate MAC address…" and a harmless "Re-run address discovery" two rows apart looked
//  the same. Symbols don't reach accessibility (an icon button speaks its tooltip), so the
//  rule is read from the source.
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct InspectorSymbolLintTests {
	// Files holding several inspectors, each of which owns one button with that glyph.
	static let separateInspectors: Set<String> = [
		"EntityInspectors.swift MachmanSymbols.delete",   // DiskInspector and MountInspector
	]

	@Test("H59: an inspector file never gives one symbol to two icon buttons")
	func oneSymbolPerIconButton() throws {
		let symbol = try NSRegularExpression(
			pattern: #"IconButton\(\s*symbol:\s*(MachmanSymbols\.\w+)"#)
		var read = 0
		var problems: [String] = []
		for file in RepoFiles.files(
			under: ["MachmanKit/Sources/MachmanDesktopUI/Inspector"], extension: "swift") {
			let source = try String(contentsOf: file, encoding: .utf8)
			let range = NSRange(source.startIndex..., in: source)
			var counts: [String: Int] = [:]
			for match in symbol.matches(in: source, range: range) {
				guard let name = Range(match.range(at: 1), in: source) else { continue }
				counts[String(source[name]), default: 0] += 1
				read += 1
			}
			for (name, count) in counts where count > 1 {
				let key = "\(file.lastPathComponent) \(name)"
				if !Self.separateInspectors.contains(key) {
					problems.append("\(RepoFiles.relativePath(file)): \(name) ×\(count)")
				}
			}
		}
		#expect(read >= 8, "the scan read only \(read) icon buttons")
		#expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
	}
}
