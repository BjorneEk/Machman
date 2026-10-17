//
//  WordingLintTests.swift
//  MachmanAPITests
//
//  The desktop's own wording rules, read from the source (SwiftCallStrings): every tooltip
//  is one sentence with no semicolon (X9), the regenerate-MAC question names the VM once in
//  one sentence (X7), and the SSH and Guest Setup questions keep their titles (H11), with
//  every confirmation dialog's message one sentence (standing rule 7). Dialogs and
//  tooltips don't render offscreen, and these strings live only in their views.
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct WordingLintTests {
	// Where the desktop, the agent and the vmhost word what a person reads.
	static let surfaces = [
		"MachmanKit/Sources/MachmanDesktopUI", "MachmanKit/Sources/MachmanUI",
		"MachmanKit/Sources/MachmanDesktopCore", "MachmanDesktop", "MachmanAgent",
		"MachmanVMHost",
	]

	@Test("W4-33: every tooltip is one sentence with no semicolon")
	func everyTooltipIsOneSentence() throws {
		var read = 0
		var problems: [String] = []
		for file in RepoFiles.files(under: Self.surfaces, extension: "swift") {
			let source = try String(contentsOf: file, encoding: .utf8)
			let path = RepoFiles.relativePath(file)
			// An icon button's or add tile's name and disabled reason are tooltips too (H57).
			for marker in [".help(", "tooltip: ", "IconButton(", "AddTile("] {
				for (line, text) in SwiftCallStrings.arguments(of: marker, in: source)
				where Self.says(text) {
					read += 1
					let words = SwiftCallStrings.words(text)
					if words.contains(";") || SwiftCallStrings.sentences(text) > 1 {
						problems.append("\(path):\(line): \(text)")
					}
				}
			}
		}
		#expect(read > 80, "the scan read only \(read) tooltips")
		#expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
	}

	// Short words a Title Case button or menu item keeps lowercase mid-title (HIG): "Add
	// from Disk…", "Show in Finder", "Move to New Window". Particles of a phrasal verb ("Log
	// In", "Turn On", "Shut Down") are not in the list.
	static let shortWords: Set<String> = [
		"A", "An", "And", "As", "At", "By", "For", "From", "Into", "Of", "Or", "The", "To",
		"With",
	]

	@Test("W9: button and menu titles keep short prepositions lowercase")
	func titleCaseKeepsShortWordsLowercase() throws {
		var read = 0
		var problems: [String] = []
		for file in RepoFiles.files(under: Self.surfaces, extension: "swift") {
			let source = try String(contentsOf: file, encoding: .utf8)
			let path = RepoFiles.relativePath(file)
			// Choice( is a prompt's button, drawn from PromptCenter's content (Q31).
			for marker in ["Button(", "Label(", "Choice("] {
				for (line, text) in SwiftCallStrings.arguments(of: marker, in: source)
				where Self.says(text) {
					read += 1
					let words = SwiftCallStrings.words(text).split(separator: " ").map(String.init)
					if words.dropFirst().dropLast().contains(where: Self.shortWords.contains) {
						problems.append("\(path):\(line): \(text)")
					}
				}
			}
		}
		#expect(read > 80, "the scan read only \(read) titles")
		#expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
	}

	@Test("W4-4: the regenerate-MAC question names the VM once, in one sentence")
	func regenerateMACNamesTheVMOnce() throws {
		let source = try RepoFiles.text(
			"MachmanKit/Sources/MachmanDesktopUI/Inspector/DeviceInspectors.swift")
		let message = try #require(
			Self.dialogs(in: source).first { $0.title == "Regenerate MAC address?" }?.message,
			"the regenerate-MAC dialog lost its title or its message")
		#expect(SwiftCallStrings.sentences(message) == 1, "\(message)")
		#expect(message.components(separatedBy: "\u{27E8}vm.name\u{27E9}").count == 2,
			"\(message)")
	}

	@Test("W4-6: the alias, approval, revoke and reset questions keep their titles")
	func dialogTitlesStay() throws {
		let inspectors = "MachmanKit/Sources/MachmanDesktopUI/Inspector/"
		let ssh = try Self.dialogs(in: RepoFiles.text(inspectors + "SSHInspector.swift"))
		let setup = try Self.dialogs(in: RepoFiles.text(inspectors + "GuestSetupInspector.swift"))
		let titles = Set((ssh + setup).map(\.title))
		let vm = "\u{201C}\u{27E8}vm.name\u{27E9}\u{201D}"
		for title in [
			"Let \(vm) log in to this Mac as you?",
			"Revoke guest access for \(vm)?",
			"Reset guest setup state?",
			"Add \u{201C}\u{27E8}alias\u{27E9}\u{201D} to your SSH config?",
		] {
			#expect(titles.contains(title), "no dialog titled \(title) in \(titles.sorted())")
		}

		var messages = 0
		for file in RepoFiles.files(
			under: ["MachmanKit/Sources/MachmanDesktopUI"], extension: "swift") {
			let source = try String(contentsOf: file, encoding: .utf8)
			for dialog in Self.dialogs(in: source) {
				guard let message = dialog.message else { continue }
				messages += 1
				#expect(SwiftCallStrings.sentences(message) == 1,
					"\(RepoFiles.relativePath(file)): \(dialog.title): \(message)")
			}
		}
		// The prompt center draws the window's questions from their content (Q31): their
		// messages are said there.
		let center = "MachmanKit/Sources/MachmanDesktopCore/PromptCenter.swift"
		for call in SwiftCallStrings.calls(of: "message: ", in: try RepoFiles.text(center)) {
			for message in call.texts where !message.isEmpty {
				messages += 1
				#expect(SwiftCallStrings.sentences(message) == 1, "\(center): \(message)")
			}
		}
		#expect(messages >= 8, "the scan read only \(messages) dialog messages")
	}

	// A text says something once its placeholders are set aside (an interpolation-only
	// help is a variable's text, proved where it is made).
	static func says(_ text: String) -> Bool {
		SwiftCallStrings.words(text, placeholderAs: "").contains { $0.isLetter }
	}

	// Each confirmation dialog in `source` with a literal title: the title, and its message
	// when it is a literal (the first `message: {` before the next dialog or alert).
	static func dialogs(in source: String) -> [(title: String, message: String?)] {
		let marker = ".confirmationDialog("
		var found: [(title: String, message: String?)] = []
		var rest = Substring(source)
		while let start = rest.range(of: marker) {
			let tail = rest[start.lowerBound...]
			let after = tail.dropFirst(marker.count)
			let next = [marker, ".alert("].compactMap { after.range(of: $0)?.lowerBound }.min()
			let region = String(tail[..<(next ?? tail.endIndex)])
			let title = SwiftCallStrings.calls(of: marker, in: region).first?.texts.first
			let message = SwiftCallStrings.calls(of: "message: {", in: region).first?
				.texts.joined(separator: " ")
			if let title {
				found.append((title, message?.isEmpty == false ? message : nil))
			}
			rest = after
		}
		return found
	}
}
