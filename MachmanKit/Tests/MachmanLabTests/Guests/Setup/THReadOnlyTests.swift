//
//  THReadOnlyTests.swift
//  MachmanLabTests
//
//  L3 — the installer's rows that leave the guest as it was (help, version, dry run, the
//  interactive menu answered q), on one booted guest per OS. The row bodies live in
//  THReadOnlyRows so every OS's suite runs the same checks; each changing-nothing row compares
//  a fingerprint of /etc, /root, /home and the state dir before and after.
//

import Foundation
import MachmanAPI
import MachmanDesktopCore
import Testing

enum THReadOnlyRows {
	/// S1: --help and --version exit 0; help names the VM, version names the script version
	/// and this VM's marker.
	static func s1(_ g: any THGuest) async throws {
		let name = try await g.vm.info().name
		let help = try await g.sh("\(TH.installer) --help")
		#expect(help.status == 0, "\(help.output)")
		#expect(help.output.contains("Machman guest setup for \"\(name)\""), "\(help.output)")
		let version = try await g.sh("\(TH.installer) --version")
		#expect(version.status == 0, "\(version.output)")
		let current = try await g.vm.info().setup?.currentScriptVersion ?? 6
		#expect(version.output == "machman guest setup v\(current) (\(try g.marker()))")
	}

	/// S2: a user's --dry-run (no root) prints the guest's real OS, init, package manager,
	/// user, sshd state and report path, and changes nothing.
	static func s2(_ g: any THGuest) async throws {
		let before = try await THGuestFiles.fingerprint(g)
		let run = try await g.install("--dry-run", user: "lab")
		#expect(run.status == 0, "\(run.output)")
		#expect(run.output.contains("Dry run — nothing was changed."), "\(run.output)")
		let plan = THPlan(run.output)
		let facts = try await THFacts.read(g)
		#expect(
			plan["guest"] == "\(facts.osID) \(facts.version) (\(facts.family)), "
				+ "\(g.kind.initName) init, \(g.kind.packageManager)", "\(run.output)")
		#expect(plan["payload"] == GuestPaths.share + "/GuestSetup (over virtiofs)"
			|| plan["payload"] == GuestPaths.share + "/GuestSetup (over sshfs)")
		#expect(plan["user"] == "lab -> \(facts.labHome)", "\(run.output)")
		#expect(
			plan["ssh server"] == (facts.sshdRunning
				? "already running — make sure it stays enabled"
				: "installed, not running — enable and start"), "\(run.output)")
		#expect(
			plan["report"] == (facts.reportWritableByLab
				? GuestPaths.share + "/GuestReport"
				: "NOT writable — Machman will not learn any of this"), "\(run.output)")
		try await THFingerprint.expectUnchanged(g, since: before)
	}

	/// S3: a user's interactive run (TERM=dumb, the family's escalation) asks the feature
	/// question only, shows the plan, and q at "Proceed?" exits 3 with the guest untouched.
	static func s3(_ g: any THGuest) async throws {
		let before = try await THGuestFiles.fingerprint(g)
		let line = g.kind.escalation.apply(GuestCommand(TH.installer))
		let run = try await g.asUserShell("lab") {
			let s = g.session()
			try s.start("TERM=dumb \(line)")
			return try await s.drive(proceed: "q")
		}
		#expect(run.status == 3, "\(run.output)")
		#expect(run.output.contains("cancelled — nothing was changed."), "\(run.output)")
		// The menus and "Proceed?" only: a sudo run knows its user (no numbered choice).
		#expect(run.kinds.allSatisfy { $0 == .toggle || $0 == .proceed }, "\(run.kinds)")
		#expect(run.kinds.last == .proceed)
		#expect(THPlan(run.before(.proceed) ?? "")["user"] == "lab -> /home/lab", "\(run.output)")
		try await THFingerprint.expectUnchanged(g, since: before)
	}

	/// S5: a root console (no SUDO_USER/DOAS_USER) lists the users, picking lab makes the plan
	/// name lab; a bogus --user exits 3 with one error line.
	static func s5(_ g: any THGuest) async throws {
		let before = try await THGuestFiles.fingerprint(g)
		let s = g.session()
		try s.start("env -u SUDO_USER -u DOAS_USER TERM=dumb \(TH.installer) --ssh")
		let run = try await s.drive(
			choose: { list in
				THPrompt.numbered(list).first { $0.text.hasPrefix("lab ") }.map {
					String($0.number)
				} ?? "q"
			}, proceed: "q")
		#expect(run.status == 3, "\(run.output)")
		let list = run.before(.choose) ?? ""
		let choices = THPrompt.numbered(list)
		#expect(choices.contains { $0.text.hasPrefix("lab ") }, "\(list)")
		#expect(choices.contains { $0.text.hasPrefix("root ") }, "\(list)")
		withKnownIssue(THCards.numberedQuestion) {
			#expect(list.contains("Which user should Machman set up SSH for?"), "\(list)")
		}
		#expect(THPlan(run.before(.proceed) ?? "")["user"] == "lab -> /home/lab", "\(run.output)")

		let bogus = try await g.install("-n --user th-nosuchuser")
		#expect(bogus.status == 3, "\(bogus.output)")
		let sentence = "there is no user \"th-nosuchuser\" in this guest."
		let errors = bogus.output.split(separator: "\n").filter {
			$0.hasPrefix("[xx] ") || $0.hasPrefix("✗ ")
		}
		#expect(errors.count == 1, "\(bogus.output)")
		#expect(errors.first?.hasSuffix(sentence) == true, "\(bogus.output)")
		try await THFingerprint.expectUnchanged(g, since: before)
	}

	/// S8: on the driver console with TERM=vt100 LANG=C, a dry run and a run answered q print
	/// ASCII glyphs only, no colour, nothing wider than 80 columns.
	static func s8(_ g: any THGuest) async throws {
		let env = "TERM=vt100 LANG=C LC_ALL=C"
		let dry = g.session()
		try dry.start("\(env) \(TH.installer) -n")
		let dryRun = try await dry.drive()
		#expect(dryRun.status == 0, "\(dryRun.output)")
		#expect(dryRun.kinds.first == .multi, "vt100 takes the arrow menu")
		let dryBytes = try await dry.raw()

		let asked = g.session()
		try asked.start("\(env) \(TH.installer)")
		let cancelled = try await asked.drive(proceed: "q")
		#expect(cancelled.status == 3, "\(cancelled.output)")
		let askedBytes = try await asked.raw()

		for bytes in [dryBytes, askedBytes] {
			let text = String(decoding: bytes, as: UTF8.self)
			let lines = THConsoleSession.clean(text).split(separator: "\n").map(String.init)
			#expect(THGlyphs.colours(in: text).isEmpty, "SGR colours on a vt100 console")
			// The plan's consoles line is the known exception for the glyph and the width.
			let (consoles, rest) = (
				lines.filter { $0.hasPrefix("  consoles ") },
				lines.filter { !$0.hasPrefix("  consoles ") })
			for glyph in THGlyphs.unicode {
				let found = rest.filter { $0.contains(glyph) }
				#expect(found.isEmpty, "a UTF-8 glyph '\(glyph)' on a LANG=C console: \(found)")
			}
			#expect(rest.filter { $0.count > 80 }.isEmpty, "lines over 80 columns: \(rest)")
			if consoles.contains(where: { $0.contains("·") }) {
				withKnownIssue(THCards.consolesDot) {
					#expect(Bool(false), "\(consoles)")
				}
			}
			if consoles.contains(where: { $0.count > 80 }) {
				withKnownIssue(THCards.planWidth) {
					#expect(Bool(false), "\(consoles)")
				}
			}
			// Prose keeps its em dashes whatever the locale.
			let prose = lines.filter { line in
				line.unicodeScalars.contains { $0.value >= 0x80 && $0 != "·" }
			}
			if !prose.isEmpty {
				withKnownIssue(THCards.nonASCIIProse) {
					#expect(Bool(false), "\(prose.count) lines with non-ASCII prose")
				}
			}
		}
	}

	/// G4: TERM=dumb numbers the features and offers only the available ones (a dry run lists
	/// the rest with reasons at the end); xterm takes arrows and Space, and the plan follows.
	static func g4(_ g: any THGuest) async throws {
		let before = try await THGuestFiles.fingerprint(g)
		let dumb = g.session()
		try dumb.start("TERM=dumb \(TH.installer) -n")
		let dry = try await dumb.drive()
		#expect(dry.status == 0, "\(dry.output)")
		#expect(dry.kinds.first == .toggle, "TERM=dumb numbers the menu")
		let items = THPrompt.menu(dry.before(.toggle) ?? "")
		#expect(items.count >= 2, "\(dry.output)")
		let unavailable = THPrompt.unavailable(dry.output)
		for (title, reason) in unavailable {
			#expect(!reason.isEmpty, "\(title) is listed without a reason")
			#expect(!items.contains { $0.title.hasPrefix(title) },
				"\(title) is unavailable but offered")
		}

		// The arrow menu: Down then Space toggles item 2, and the plan reflects it.
		let second = try #require(items.count >= 2 ? items[1] : nil)
		let feature = try #require(THPrompt.planKey(forTitle: second.title))
		let xterm = g.session()
		try xterm.start("TERM=xterm-256color LANG=C.UTF-8 \(TH.installer)")
		let run = try await xterm.drive(
			multiKeys: [THKey.down, THKey.space, THKey.enter], proceed: "q")
		#expect(run.status == 3, "\(run.output)")
		#expect(run.kinds.first == .multi, "xterm takes the arrow menu")
		let plan = THPlan(run.before(.proceed) ?? "")
		#expect((plan[feature] != nil) == !second.on, "\(run.output)")
		let colours = THGlyphs.colours(in: String(decoding: try await xterm.raw(), as: UTF8.self))
		#expect(!colours.isEmpty, "xterm-256color shows colour")
		try await THFingerprint.expectUnchanged(g, since: before)
	}

	/// G16 (read-only half): the menu never offers the kernel console; the plan states it off
	/// with the flag that enables it; --help warns that the flag edits the boot loader.
	static func g16(_ g: any THGuest) async throws {
		let s = g.session()
		try s.start("TERM=dumb \(TH.installer) -n")
		let dry = try await s.drive()
		#expect(dry.status == 0, "\(dry.output)")
		let menu = dry.before(.toggle) ?? ""
		#expect(!menu.isEmpty && !menu.contains("Kernel console"), "\(menu)")
		#expect(
			THPlan(dry.output)["kernel console"]
				== "off — enable with --kernel-console (edits the boot loader)", "\(dry.output)")
		let help = try await g.sh("\(TH.installer) --help")
		#expect(help.output.contains("WARNING: EDITS THE BOOT LOADER"))
	}
}

/// The installer's plan lines ("  <key padded to 16> <value>").
struct THPlan {
	let values: [String: String]

	init(_ output: String) {
		var values: [String: String] = [:]
		for raw in THConsoleSession.clean(output).split(separator: "\n") {
			let line = Array(raw)
			guard line.count > 19, line[0] == " ", line[1] == " ", line[2] != " ",
				line[18] == " "
			else { continue }
			let key = String(line[2..<18]).trimmingCharacters(in: .whitespaces)
			if values[key] == nil { values[key] = String(line[19...]) }
		}
		self.values = values
	}

	subscript(key: String) -> String? { values[key] }
}

/// The installer's prompts as a console shows them.
enum THPrompt {
	/// "  <n>) <text>" lines.
	static func numbered(_ text: String) -> [(number: Int, text: String)] {
		THConsoleSession.clean(text).split(separator: "\n").compactMap { line in
			let trimmed = line.drop { $0 == " " }
			guard let paren = trimmed.firstIndex(of: ")"),
				let number = Int(trimmed[..<paren]),
				trimmed.index(after: paren) < trimmed.endIndex
			else { return nil }
			return (number, String(trimmed[trimmed.index(paren, offsetBy: 2)...]))
		}
	}

	/// A feature menu's numbered lines: "  <n>) <mark> <title> <note>", the mark ASCII
	/// ([x] / [ ]) or UTF-8 (◉ / ○) by the console's locale.
	static func menu(_ text: String) -> [(number: Int, on: Bool, title: String)] {
		numbered(text).compactMap { item in
			for (mark, on) in [("[x] ", true), ("[ ] ", false), ("◉ ", true), ("○ ", false)]
			where item.text.hasPrefix(mark) {
				return (item.number, on, String(item.text.dropFirst(mark.count)))
			}
			return nil
		}
	}

	/// The "Unavailable here:" list: title → reason.
	static func unavailable(_ output: String) -> [(String, String)] {
		let lines = THConsoleSession.clean(output).split(separator: "\n").map(String.init)
		guard let start = lines.firstIndex(of: "Unavailable here:") else { return [] }
		return lines[(start + 1)...].prefix { $0.hasPrefix("   ") }.compactMap { line in
			let body = line.trimmingCharacters(in: .whitespaces)
			guard let colon = body.range(of: ": ") else { return nil }
			return (String(body[..<colon.lowerBound]), String(body[colon.upperBound...]))
		}
	}

	/// The plan key a feature's title selects (feature_title → <f>_plan).
	static func planKey(forTitle title: String) -> String? {
		let keys = [
			"Console logins": "consoles", "SSH (Mac -> guest)": "ssh server",
			"Guest -> host SSH": "guest -> host", "sshfs (mount host folders)": "sshfs",
			"Automount the share (virtiofs)": "share automount",
			"Automount sshfs folders": "sshfs automount",
		]
		return keys.first { title.hasPrefix($0.key) }?.value
	}
}

/// What a terminal shows of the installer's glyphs and colours.
enum THGlyphs {
	/// The UTF-8 glyph set (05-lib.sh ui_detect); the ASCII set replaces each.
	static let unicode = ["✓", "→", "✗", "❯", "◉", "○", "·"]

	private static let sgr = try! NSRegularExpression(pattern: "\u{1B}\\[([0-9;]*)m")

	/// The SGR sequences in `text` that set a colour (30–49, 90–107, 38;5 / 48;5).
	static func colours(in text: String) -> [String] {
		let range = NSRange(text.startIndex..., in: text)
		return sgr.matches(in: text, range: range).compactMap { match in
			let params = (text as NSString).substring(with: match.range(at: 1))
			let numbers = params.split(separator: ";").compactMap { Int($0) }
			let coloured = numbers.contains { (30...49).contains($0) || (90...107).contains($0) }
			return coloured ? params : nil
		}
	}
}

/// The guest's own facts a plan must agree with.
struct THFacts {
	var osID = ""
	var version = ""
	var family = ""
	var labHome = ""
	var sshdRunning = false
	var reportWritableByLab = false

	static func read(_ g: any THGuest) async throws -> THFacts {
		var facts = THFacts()
		if g.kind.isLinux {
			facts.osID = try await g.check("sed -n 's/^ID=//p' /etc/os-release | tr -d '\"'")
			facts.version = try await g.check(
				"sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '\"'")
		} else {
			facts.osID = g.kind.osID
			facts.version = try await g.check("uname -r")
		}
		facts.family = g.kind.osID
		facts.labHome = try await g.check("getent passwd lab | cut -d: -f6 || echo /home/lab")
		facts.sshdRunning = try await g.sh(sshdActive(g.kind)).status == 0
		facts.reportWritableByLab = try await g.sh(
			"test -d \(GuestPaths.share)/GuestReport -a -w \(GuestPaths.share)/GuestReport",
			user: "lab").status == 0
		return facts
	}

	/// The guest's own answer to "does sshd start at boot" (as root).
	static func sshdEnabled(_ kind: THGuestKind) -> String {
		switch kind {
		case .debian: "systemctl is-enabled --quiet ssh"
		case .debianSysv: "ls /etc/rc2.d/S*ssh >/dev/null 2>&1"
		case .alpine: "rc-update show default | grep -qw sshd"
		case .openbsd: "rcctl ls on | grep -qx sshd"
		case .netbsd: "grep -q '^sshd=YES' /etc/rc.conf"
		default: "[ \"$(sysrc -n sshd_enable)\" = YES ]"
		}
	}

	/// The guest's own answer to "is sshd running" (as root).
	static func sshdActive(_ kind: THGuestKind) -> String {
		switch kind {
		case .debian: "systemctl is-active --quiet ssh"
		case .debianSysv: "pgrep -x sshd >/dev/null"
		case .alpine: "rc-service sshd status >/dev/null 2>&1"
		case .openbsd: "rcctl check sshd >/dev/null"
		case .netbsd: "/etc/rc.d/sshd status >/dev/null"
		default: "service sshd status >/dev/null 2>&1"
		}
	}
}

enum THFingerprint {
	/// The trees are as they were at `before`; a mismatch names the changed files.
	static func expectUnchanged(_ g: any THGuest, since before: THGuestFiles.Fingerprint)
		async throws {
		let after = try await THGuestFiles.fingerprint(g)
		if after.digest != before.digest {
			let diff = await THGuestFiles.diff(g, before, after)
			Issue.record("the guest changed:\n\(diff)")
		}
	}
}

/// Draft product cards a known-issue test names (the orchestrator files them).
enum THCards {
	static let nonASCIIProse: Comment =
		"The guest installer prints em dashes on a LANG=C vt100 console"
	static let numberedQuestion: Comment =
		"A numbered choice on TERM=dumb prints its first item instead of its question"
	static let consolesDot: Comment =
		"The plan's consoles line joins devices with a UTF-8 dot on a LANG=C console"
	static let planWidth: Comment =
		"The installer's plan lines run past 80 columns on a console"
}

// L3 — the installer on the prepared Debian guest under VZ.
@Suite(
	"L3 Guest Setup — Debian read-only rows", .serialized, .enabled(if: Lab.runs(.l3)),
	.thGuest(.debian))
struct THReadOnlyDebianTests {
	@Test("S1: install.sh --help and --version exit 0 and name the VM")
	func s1() async throws { try await THShared.row(THReadOnlyRows.s1) }

	@Test("S2: --dry-run as a user prints the guest's real plan and changes nothing")
	func s2() async throws { try await THShared.row(THReadOnlyRows.s2) }

	@Test("S3: answering q at the plan exits 3 and leaves the guest untouched")
	func s3() async throws { try await THShared.row(THReadOnlyRows.s3) }

	@Test("S5: a root console lists the users, and a bogus --user exits 3")
	func s5() async throws { try await THShared.row(THReadOnlyRows.s5) }

	@Test("S8: a vt100 LANG=C console run is ASCII, colourless and within 80 columns")
	func s8() async throws { try await THShared.row(THReadOnlyRows.s8) }

	@Test("G4: the feature menu numbers items on TERM=dumb, takes arrows on xterm")
	func g4() async throws { try await THShared.row(THReadOnlyRows.g4) }

	@Test("G16: the menu never offers the kernel console; --help and the plan state it")
	func g16() async throws { try await THShared.row(THReadOnlyRows.g16) }
}
