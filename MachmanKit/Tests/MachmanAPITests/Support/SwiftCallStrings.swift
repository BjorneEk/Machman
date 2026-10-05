//
//  SwiftCallStrings.swift
//  MachmanAPITests
//
//  The text a SwiftUI call shows, read from Swift source for wording lints: the string
//  literals inside one call's argument (`.help(`, `tooltip: `, `.confirmationDialog(`,
//  `message: {`), joined where `+` concatenates them, split where `??`, a ternary, a label
//  or a comma puts them on separate branches — each branch is a text a person may read.
//  An interpolation stays as a placeholder naming its expression (`⟨vm.name⟩`). Comments
//  and markers inside string literals don't count. A lexer, not a parser: enough of Swift's
//  literal and comment syntax to read the desktop's own calls, nothing more.
//

import Foundation

enum SwiftCallStrings {
	// One call: the line its marker is on, and each text branch of its argument.
	struct Call: Equatable, CustomStringConvertible {
		let line: Int
		let texts: [String]

		var description: String { "\(line): \(texts)" }
	}

	// Every text branch of every call of `marker` in `source`, with the marker's line.
	static func arguments(of marker: String, in source: String) -> [(line: Int, text: String)] {
		calls(of: marker, in: source).flatMap { call in call.texts.map { (call.line, $0) } }
	}

	// Each call of `marker` in code. A marker ending in `(` or `{` reads to its matching
	// close; any other (an argument label) reads to the next `,` or close at its own depth.
	static func calls(of marker: String, in source: String) -> [Call] {
		var lexer = Lexer(Array(source))
		let mark = Array(marker)
		var found: [Call] = []
		while !lexer.atEnd {
			if lexer.skipTrivia() { continue }
			if lexer.peekLiteral {
				_ = lexer.literal()
				continue
			}
			if lexer.starts(with: mark) {
				let line = lexer.line
				lexer.advance(mark.count)
				found.append(Call(line: line, texts: lexer.argument(opener: mark.last)))
				continue
			}
			lexer.advance(1)
		}
		return found
	}

	// Sentences in `text`: a terminal . ? or ! followed by whitespace or the end, after a
	// trailing ellipsis (a menu title's “…”) is set aside.
	static func sentences(_ text: String) -> Int {
		var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
		for ellipsis in ["\u{2026}", "..."] where body.hasSuffix(ellipsis) {
			body.removeLast(ellipsis.count)
		}
		let chars = Array(body)
		var count = 0
		for (index, char) in chars.enumerated() where ".?!".contains(char) {
			if index + 1 == chars.count || chars[index + 1].isWhitespace { count += 1 }
		}
		// Text without a terminal mark is one sentence (a fragment), as tooltips mostly are.
		let last = chars.last.map { ".?!".contains($0) } ?? true
		return count + (last ? 0 : 1)
	}
}

// Swift source as characters, with the line count kept as it moves.
private struct Lexer {
	let chars: [Character]
	var index = 0
	var line = 1

	init(_ chars: [Character]) {
		self.chars = chars
	}

	var atEnd: Bool { index >= chars.count }

	func peek(_ offset: Int = 0) -> Character? {
		index + offset < chars.count ? chars[index + offset] : nil
	}

	func starts(with pattern: [Character]) -> Bool {
		guard index + pattern.count <= chars.count else { return false }
		return Array(chars[index..<(index + pattern.count)]) == pattern
	}

	mutating func advance(_ count: Int) {
		for _ in 0..<count where index < chars.count {
			if chars[index] == "\n" { line += 1 }
			index += 1
		}
	}

	// Skips one newline-free run of whitespace, a // comment or a /* */ comment; false
	// when none starts here.
	mutating func skipTrivia() -> Bool {
		if starts(with: ["/", "/"]) {
			while let char = peek(), char != "\n" { advance(1) }
			return true
		}
		if starts(with: ["/", "*"]) {
			advance(2)
			while !atEnd && !starts(with: ["*", "/"]) { advance(1) }
			advance(2)
			return true
		}
		return false
	}

	// A string literal starts here: `"`, or raw `#"`.
	var peekLiteral: Bool {
		var offset = 0
		while peek(offset) == "#" { offset += 1 }
		return peek(offset) == "\""
	}

	// Reads the string literal starting here: its text, interpolations as ⟨expression⟩.
	mutating func literal() -> String {
		var hashes = 0
		while peek() == "#" {
			hashes += 1
			advance(1)
		}
		let multiline = starts(with: ["\"", "\"", "\""])
		advance(multiline ? 3 : 1)
		let quotes: [Character] = multiline ? ["\"", "\"", "\""] : ["\""]
		let close = quotes + Array(repeating: "#", count: hashes)
		let escape: [Character] = ["\\"] + Array(repeating: "#", count: hashes)
		var text = ""
		while !atEnd {
			if starts(with: close) {
				advance(close.count)
				break
			}
			if starts(with: escape) {
				advance(escape.count)
				text += escaped()
				continue
			}
			if !multiline, peek() == "\n" { break }   // unterminated: stop at the line
			text.append(chars[index])
			advance(1)
		}
		return text
	}

	// After a backslash: an interpolation's placeholder or the escaped character.
	private mutating func escaped() -> String {
		guard let char = peek() else { return "" }
		advance(1)
		switch char {
		case "(":
			return "\u{27E8}" + interpolation() + "\u{27E9}"
		case "n": return "\n"
		case "t": return "\t"
		case "0": return "\0"
		case "u":
			guard peek() == "{" else { return "u" }
			advance(1)
			var hex = ""
			while let digit = peek(), digit != "}" {
				hex.append(digit)
				advance(1)
			}
			advance(1)
			return UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } ?? ""
		default:
			return String(char)   // \" \\ \'
		}
	}

	// An interpolation's expression, up to its closing paren (nested parens and literals
	// inside it are its own).
	private mutating func interpolation() -> String {
		var depth = 1
		var text = ""
		while !atEnd {
			if peekLiteral {
				text += "\"" + literal() + "\""
				continue
			}
			let char = chars[index]
			if char == "(" { depth += 1 }
			if char == ")" {
				depth -= 1
				if depth == 0 {
					advance(1)
					break
				}
			}
			text.append(char)
			advance(1)
		}
		return text
	}

	// One call's argument after its marker: each literal branch's joined text.
	mutating func argument(opener: Character?) -> [String] {
		let bracketed = opener == "(" || opener == "{" || opener == "["
		var depth = bracketed ? 1 : 0
		var texts: [String] = []
		var current: String?
		func split() {
			if let text = current { texts.append(text) }
			current = nil
		}
		while !atEnd {
			if skipTrivia() { continue }
			if peekLiteral {
				current = (current ?? "") + literal()
				continue
			}
			let char = chars[index]
			switch char {
			case "(", "[", "{":
				depth += 1
			case ")", "]", "}":
				if depth == 0 {   // an unbracketed argument ends at its call's close
					split()
					return texts
				}
				depth -= 1
				if bracketed && depth == 0 {
					advance(1)
					split()
					return texts
				}
			case ",":
				if !bracketed && depth == 0 {
					split()
					return texts
				}
				split()
			case ":":
				split()
			case "?":
				// A fallback (??) or a ternary (spaced); optional chaining (x?.y) joins.
				if peek(1) == "?" || peek(1)?.isWhitespace == true { split() }
				if peek(1) == "?" { advance(1) }
			default:
				break
			}
			advance(1)
		}
		split()
		return texts
	}
}
