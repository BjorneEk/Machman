//
//  SwiftCallStringsTests.swift
//  MachmanAPITests
//
//  The wording lints' reader on a sample of the shapes the desktop's calls take: a text
//  concatenated across lines, a fallback after ??, a ternary, an interpolation, a label,
//  and a marker inside a comment or a string that isn't a call.
//

import Testing

// L1: lint (repo files) — the reader the wording lints use.
struct SwiftCallStringsTests {
	private static let sample = [
		#"IconButton(symbol: MachmanSymbols.delete,"#,
		#"    tooltip: vm.refusal(.removeDisk) ?? (owned"#,
		#"        ? "Delete disk…" : "Remove disk — the file stays")) {"#,
		#"    remove()"#,
		#"}"#,
		#"Toggle("x", isOn: $on)"#,
		#"    .help("Exposes virtualization extensions "  // a comment: .help("no")"#,
		#"        + "to the guest (EFI/Linux)")"#,
		#".help(vm.ssh?.reachabilityDetail.map { "SSH: \($0) — try again" } ?? "SSH did not")"#,
		#"let words = ".help(\"in a string\")""#,
		#".confirmationDialog("Revoke guest access for “\(vm.name)”?", isPresented: $on) {"#,
		#"    Button("Revoke") {}"#,
		#"} message: {"#,
		#"    Text("Removes exactly this VM’s key line from "#,
		#"        + "~/.ssh/authorized_keys.")"#,
		#"}"#,
	].joined(separator: "\n")

	@Test("Q18: the call-string reader joins concatenated literals across lines")
	func readsCallsAcrossLines() {
		let tooltips = SwiftCallStrings.calls(of: "tooltip: ", in: Self.sample)
		#expect(tooltips == [.init(
			line: 2, texts: ["Delete disk\u{2026}", "Remove disk — the file stays"])])

		let helps = SwiftCallStrings.calls(of: ".help(", in: Self.sample)
		#expect(helps == [
			.init(line: 7, texts: ["Exposes virtualization extensions to the guest (EFI/Linux)"]),
			.init(line: 9, texts: ["SSH: \u{27E8}$0\u{27E9} — try again", "SSH did not"]),
		])

		let titles = SwiftCallStrings.calls(of: ".confirmationDialog(", in: Self.sample)
		#expect(titles == [
			.init(line: 11, texts: ["Revoke guest access for “\u{27E8}vm.name\u{27E9}”?"]),
		])
		let messages = SwiftCallStrings.arguments(of: "message: {", in: Self.sample)
		#expect(messages.map(\.text)
			== ["Removes exactly this VM’s key line from ~/.ssh/authorized_keys."])
		#expect(messages.map(\.line) == [13])
	}

	@Test("Q18: a sentence ends at a stop before a space or the end, never at an ellipsis")
	func countsSentences() {
		#expect(SwiftCallStrings.sentences("Delete disk\u{2026}") == 1)
		#expect(SwiftCallStrings.sentences("Copy this Mac’s public key") == 1)
		#expect(SwiftCallStrings.sentences("Adds one line to ~/.ssh/config.") == 1)
		#expect(SwiftCallStrings.sentences("One. Two.") == 2)
		#expect(SwiftCallStrings.sentences("Is it? Then go") == 2)
		#expect(SwiftCallStrings.sentences("v3.1 of \u{27E8}vm.name\u{27E9}") == 1)
	}
}
