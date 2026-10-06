//
//  HostQuietLintTests.swift
//  MachmanAPITests
//
//  Test code never reaches the user's screen, focus, pasteboard, permissions or settings: no
//  AX server or screen-capture call (a TCC prompt), no audio or camera, no activation, no
//  window ordered front, no modal, no Finder or app launch, no write to the real defaults,
//  and only OffscreenHost makes the NSApplication (its tripwire). Scanned: every Swift file
//  under MachmanKit/Tests (but MachmanLabTests, which lab.sh audits live) and MachmanKit/Tools,
//  code only — comments and string literals don't count. A line marked
//  `// host-quiet: <reason>` is exempt: the tripwires themselves, and the self-tests that
//  provoke them on purpose.
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct HostQuietLintTests {
	@Test("Q18: test code never prompts, activates, orders windows or touches the pasteboard")
	func testCodeStaysQuiet() throws {
		let tests = RepoFiles.files(under: ["MachmanKit/Tests"], extension: "swift")
			.filter { !RepoFiles.relativePath($0).hasPrefix("MachmanKit/Tests/MachmanLabTests/") }
		let tools = RepoFiles.files(under: ["MachmanKit/Tools"], extension: "swift")
		#expect(tests.count > 100 && !tools.isEmpty, "the scan found too few files")
		var hits: [RepoFiles.Match] = []
		for file in tests + tools {
			let text = try String(contentsOf: file, encoding: .utf8)
			let path = RepoFiles.relativePath(file)
			hits += HostQuietLint.scan(path: path, text: text, inTests: path.contains("/Tests/"))
		}
		#expect(hits.isEmpty, "\(hits.map(\.description).joined(separator: "\n"))")
	}

	@Test("Q18: the host-quiet scan flags a provoked call")
	func scanFlagsAProvokedCall() {
		// One single-line literal per line, so this file's own scan reads them as strings.
		let sample = [
			"let app = NSApplication.shared",
			"NSPasteboard.general.clearContents()",
			"NSApp.activate()   // host-quiet: a reason",
			"// NSApp.activate() in a comment",
			"let words = \"NSApp.activate() in a string\"",
			"let open = \"/usr/bin/open\"",
			"let watch = PasteboardWatch.general",
			"let source = PasteboardWatch.generalSource(testMode: true)",
		].joined(separator: "\n")
		let hits = HostQuietLint.scan(path: "Sample.swift", text: sample, inTests: true)
		#expect(hits.map(\.line) == [1, 2, 6, 7], "\(hits)")
		#expect(HostQuietLint.scan(path: "Sample.swift", text: sample, inTests: false)
			.map(\.line) == [2, 6, 7])
	}
}

enum HostQuietLint {
	static let marker = "host-quiet:"

	// Calls matched in code with its string literals blanked.
	static let apiPatterns = [
		#"\bAXUIElement"#, #"\bAXIsProcessTrusted"#,
		#"\bCGRequestScreenCaptureAccess\b"#, #"\bCGPreflightScreenCaptureAccess\b"#,
		#"\bCGWindowListCreateImage\b"#, #"\bSCShareableContent\b"#, #"\bSCStream\b"#,
		#"\bSCScreenshotManager\b"#,
		#"\bAVCaptureDevice\b"#, #"\bAVAudioEngine\b"#, #"\bAVAudioRecorder\b"#,
		#"NSPasteboard\.general"#, #"PasteboardWatch\.general\b"#,
		#"NSApp\.activate"#, #"NSApplication\.shared\.activate"#,
		#"NSRunningApplication.*\.activate"#,
		#"setActivationPolicy\(\.(regular|accessory)\)"#,
		#"makeKeyAndOrderFront"#, #"orderFrontRegardless"#, #"\.orderFront\("#, #"\.makeKey\("#,
		#"\.runModal\("#, #"beginSheetModal"#, #"beginModalSession"#,
		#"NSWorkspace\.shared\.(open|openApplication|activateFileViewerSelecting|selectFile"#
			+ #"|launchApplication|recycle)"#,
		#"UserDefaults\.standard\.(set|removeObject|setPersistentDomain|removePersistentDomain)"#,
	].map { try! NSRegularExpression(pattern: $0) }

	// Executables a test must never run, as quoted literals (matched with strings kept).
	static let executables = [
		"/usr/bin/open", "/usr/bin/osascript", "/bin/launchctl",   // host-quiet: the list
	]
	static let executablePatterns = executables.map {
		try! NSRegularExpression(
			pattern: "\"" + NSRegularExpression.escapedPattern(for: $0) + "\"")
	}

	// Only OffscreenHost makes the app (its tripwire subclass), and only in tests: the render
	// tool's main.swift makes its own.
	static let testsOnlyPatterns = [#"NSApplication\.shared"#]
		.map { try! NSRegularExpression(pattern: $0) }

	static func scan(path: String, text: String, inTests: Bool) -> [RepoFiles.Match] {
		let lines = text.components(separatedBy: "\n")
		let split = lines.map(Self.split)
		let code = split.map(\.code).joined(separator: "\n")
		let bare = split.map(\.bare).joined(separator: "\n")
		var hitLines = Set<Int>()
		for pattern in apiPatterns + (inTests ? testsOnlyPatterns : []) {
			hitLines.formUnion(RepoFiles.scan(path: path, text: bare, pattern: pattern).map(\.line))
		}
		for pattern in executablePatterns {
			hitLines.formUnion(RepoFiles.scan(path: path, text: code, pattern: pattern).map(\.line))
		}
		return hitLines.sorted().compactMap { number in
			split[number - 1].exempt
				? nil : RepoFiles.Match(path: path, line: number, text: lines[number - 1])
		}
	}

	// A line's code (its `//` comment cut off), the same with every string literal emptied,
	// and whether its comment carries the exemption marker. Single-line literals only: a
	// line inside a multi-line literal reads as code, which can only add hits.
	static func split(_ line: String) -> (code: String, bare: String, exempt: Bool) {
		var code = "", bare = ""
		var inString = false, escaped = false
		var index = line.startIndex
		while index < line.endIndex {
			let char = line[index]
			if inString {
				code.append(char)
				if escaped {
					escaped = false
				} else if char == "\\" {
					escaped = true
				} else if char == "\"" {
					inString = false
					bare.append(char)
				}
			} else if char == "/", line[index...].hasPrefix("//") {
				let comment = line[index...]
				return (code, bare, comment.contains(marker))
			} else {
				code.append(char)
				bare.append(char)
				if char == "\"" { inString = true }
			}
			index = line.index(after: index)
		}
		return (code, bare, false)
	}
}
