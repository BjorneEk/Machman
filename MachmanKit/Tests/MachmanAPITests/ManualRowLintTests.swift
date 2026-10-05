//
//  ManualRowLintTests.swift
//  MachmanAPITests
//
//  Manual rows whose rule is a property of the source, read from this checkout's files: no
//  text still says safe mode is to come (row 15), the Duplicate and Save as New VM sheets
//  wire Esc and Return (W1-4), the disk Grow button takes no Return of its own (W3-22),
//  and quitting the desktop flushes its stores (W1-17). Each rule lives in one place of a
//  view or the app target, which no headless test hosts, so the source is what proves it.
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct ManualRowLintTests {
	@Test("15: no text says safe mode is still to ship")
	func noTextSaysSafeModeIsToShip() throws {
		// Built from parts, so this file never matches itself.
		let phrase = "when safe mode " + "ships"
		let pattern = try NSRegularExpression(
			pattern: NSRegularExpression.escapedPattern(for: phrase),
			options: .caseInsensitive)
		let swift = RepoFiles.grep(
			pattern, under: ["MachmanKit/Sources", "MachmanDesktop", "MachmanAgent",
				"MachmanVMHost"], extension: "swift")
		let scripts = RepoFiles.grep(
			pattern, under: ["MachmanKit/Sources/MachmanCore/GuestScripts"], extension: "sh")
		let docs = RepoFiles.grep(pattern, under: ["docs"], extension: "md")
		let scanned = RepoFiles.files(under: ["MachmanKit/Sources"], extension: "swift")
		#expect(scanned.count > 100, "the scan found too few files")
		let hits = swift + scripts + docs
		#expect(hits.isEmpty, "\(hits.map(\.description).joined(separator: "\n"))")
	}

	@Test("W1-4: the Duplicate and Save as New VM sheets cancel on Esc, confirm on Return")
	func sheetsCancelOnEscAndConfirmOnReturn() throws {
		let sheets = [
			("MachmanKit/Sources/MachmanDesktopUI/CopyVMSheet.swift", "Duplicate"),
			("MachmanKit/Sources/MachmanDesktopUI/SafeSaveSheet.swift", "Save"),
		]
		for (path, confirm) in sheets {
			let source = try RepoFiles.text(path)
			#expect(
				Self.shortcut(after: "Button(\"Cancel\"", in: source) == ".cancelAction",
				"\(path): Cancel has no Esc")
			#expect(
				Self.shortcut(after: "Button(\"\(confirm)\"", in: source) == ".defaultAction",
				"\(path): \(confirm) has no Return")
		}
	}

	@Test("W3-22: Return reaches no Grow button outside its field")
	func growButtonTakesNoReturn() throws {
		let source = try RepoFiles.text(
			"MachmanKit/Sources/MachmanDesktopUI/Inspector/EntityInspectors.swift")
		let row = try #require(
			Self.region(of: source, from: "private func growRow", to: "private func"),
			"growRow moved: the lint has nothing to read")
		#expect(row.contains("Button(\"Grow\""), "the Grow button left growRow")
		#expect(row.contains(".onSubmit(grow)"), "Return in the field no longer grows")
		#expect(!row.contains("keyboardShortcut"), "\(row)")
	}

	@Test("W1-17: quitting the desktop flushes its canvas, profile and activity stores")
	func quittingFlushesTheStores() throws {
		let source = try RepoFiles.text("MachmanDesktop/MachmanDesktopApp.swift")
		let body = try #require(
			Self.region(of: source, from: "func applicationWillTerminate", to: "\n\t}"),
			"applicationWillTerminate moved: the lint has nothing to read")
		for flush in ["canvases.flush()", "profiles?.flush()", "activity.flush()"] {
			#expect(body.contains(flush), "applicationWillTerminate no longer calls \(flush)")
		}
	}

	// The shortcut (".cancelAction") of the first .keyboardShortcut( after `marker`, nil if
	// either is missing or another Button( comes first.
	static func shortcut(after marker: String, in source: String) -> String? {
		guard let start = source.range(of: marker) else { return nil }
		let rest = source[start.upperBound...]
		guard let call = rest.range(of: ".keyboardShortcut(") else { return nil }
		if let next = rest.range(of: "Button("), next.lowerBound < call.lowerBound {
			return nil
		}
		let argument = rest[call.upperBound...].prefix { $0 != ")" && $0 != "," }
		return String(argument).trimmingCharacters(in: .whitespaces)
	}

	// From the first `start` to the next `end` after it (exclusive), nil if either is missing.
	static func region(of source: String, from start: String, to end: String) -> String? {
		guard let begin = source.range(of: start),
			let stop = source[begin.upperBound...].range(of: end)
		else { return nil }
		return String(source[begin.lowerBound..<stop.lowerBound])
	}
}
