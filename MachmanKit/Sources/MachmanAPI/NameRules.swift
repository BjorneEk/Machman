//
//  NameRules.swift
//  MachmanAPI
//
//  One validator per identifier kind (PR8), shared by the daemon's entry points and the
//  desktop's forms so both say the same thing in the same words. Applied where a name ENTERS
//  — a create, a rename, an add — and never at load: a config stored before a rule existed
//  keeps working. Reasons are one sentence without a trailing period: the daemon throws them
//  as the error message, the forms show them under the field.
//
//  Foundation only. The engine adds Virtualization's own share-name check on top of the
//  mount-tag rule, so VZ stays the authority if it ever tightens.
//

import Foundation

// Names the user gives things that end up as file or directory names.
public enum NameRule: Sendable {
	case vmName      // the VM's directory in the library
	case diskName    // <name>.raw in the VM's directory
	case mountTag    // a directory name inside the VM's one virtiofs share
	case kernelTag   // <kernels>/<role>/<tag>/

	private var subject: String {
		switch self {
		case .vmName: return "A VM name"
		case .diskName: return "A disk name"
		case .mountTag: return "A mount tag"
		case .kernelTag: return "A kernel tag"
		}
	}

	// NAME_MAX is 255 bytes; a disk's file adds ".raw".
	public var maxBytes: Int { self == .diskName ? 251 : 255 }

	// What VZMultipleDirectoryShare.validateName refuses besides "/" and the dot names
	// (measured on macOS 26). It accepts tabs and line breaks; the control check covers them.
	private static let shareNameRefused: Set<Unicode.Scalar> = [":", "\\", "*", "?", "|", "<", ">"]

	public func trimmed(_ raw: String) -> String {
		raw.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// The reason `name`, exactly as given, can't be used — nil when it can.
	public func problem(_ name: String) -> String? {
		guard let first = name.unicodeScalars.first, let last = name.unicodeScalars.last else {
			return "\(subject) can't be empty"
		}
		if CharacterSet.whitespaces.contains(first) || CharacterSet.whitespaces.contains(last) {
			return "\(subject) can't start or end with a space"
		}
		if name.hasPrefix(".") {
			return "\(subject) can't start with a dot"
		}
		if name.contains("/") {
			return "\(subject) can't contain \u{201C}/\u{201D}"
		}
		if Self.hasControlCharacters(name) {
			return "\(subject) can't contain tabs, line breaks or other control characters"
		}
		if self == .mountTag,
			let refused = name.unicodeScalars.first(where: { Self.shareNameRefused.contains($0) }) {
			return "A mount tag can't contain \u{201C}\(refused)\u{201D}"
		}
		if name.utf8.count > maxBytes {
			return "\(subject) is too long"
		}
		if self == .mountTag, ReservedShareNames.all.contains(name) {
			return "\u{201C}\(name)\u{201D} is reserved by Machman"
		}
		return nil
	}

	// Throws the problem as invalidArgument — alreadyExists for a reserved mount tag, the
	// code that check has always used.
	public func validate(_ name: String) throws {
		guard let problem = problem(name) else { return }
		let reserved = self == .mountTag && ReservedShareNames.all.contains(name)
		throw MachmanError(code: reserved ? .alreadyExists : .invalidArgument, message: problem)
	}

	// Trim, then validate: the entry rule for names the engine may trim (disks, tags). VM
	// names are refused rather than trimmed — the router keys on the name as sent.
	public func normalized(_ raw: String) throws -> String {
		let name = trimmed(raw)
		try validate(name)
		return name
	}

	// A usable name derived from something the user did not type (a dropped folder, an
	// imported file): the offending characters become "-", leading dots go, the end is cut
	// to fit. `fallback` when nothing usable is left.
	public func suggestion(from raw: String, fallback: String) -> String {
		var scalars = String.UnicodeScalarView()
		for scalar in trimmed(raw).unicodeScalars {
			let refused = scalar == "/" || Self.isControl(scalar)
				|| (self == .mountTag && Self.shareNameRefused.contains(scalar))
			scalars.append(refused ? "-" : scalar)
		}
		var name = trimmed(String(String(scalars).drop { $0 == "." }))
		while name.utf8.count > maxBytes {
			name.removeLast()
		}
		name = trimmed(name)
		return problem(name) == nil ? name : fallback
	}

	public static func hasControlCharacters(_ string: String) -> Bool {
		string.unicodeScalars.contains(where: isControl)
	}

	private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.properties.generalCategory {
		case .control, .lineSeparator, .paragraphSeparator: return true
		default: return false
		}
	}
}

// The name a VM answers to in ~/.ssh: an ssh_config Host pattern, so glob characters would
// silently capture unrelated hosts, and a space ends the word.
public enum SSHAliasRule {
	public static let maxLength = 64
	public static let defaultSuffix = ".machman"

	static func isAliasCharacter(_ scalar: Unicode.Scalar) -> Bool {
		isASCIILetterOrDigit(scalar) || scalar == "." || scalar == "-" || scalar == "_"
	}

	static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
		("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
	}

	// The charset alone, no length cap (a derived default may run long).
	public static func isWellFormed(_ alias: String) -> Bool {
		guard let first = alias.unicodeScalars.first, isASCIILetterOrDigit(first) else {
			return false
		}
		return alias.unicodeScalars.allSatisfy(isAliasCharacter)
	}

	// What the user may type as an alias.
	public static func problem(_ alias: String) -> String? {
		if alias.count > maxLength {
			return "An SSH alias can be at most \(maxLength) characters"
		}
		if !isWellFormed(alias) {
			return "An SSH alias must start with a letter or digit and use only letters, "
				+ "digits, dots, dashes and underscores"
		}
		return nil
	}

	public static func validate(_ alias: String) throws {
		if let problem = problem(alias) {
			throw MachmanError(code: .invalidArgument, message: problem)
		}
	}

	// "<vm>.machman", mapped into the alias charset (decision 4: "dev copy" →
	// dev-copy.machman). A name that already gives a well-formed alias keeps it, so no
	// working alias changes. Otherwise accents drop (café → cafe), anything else becomes
	// one "-", and "-._" are trimmed off both ends; a name with no ASCII letters or digits
	// at all gets a stable hash of itself.
	public static func defaultAlias(for vmName: String) -> String {
		let plain = vmName + defaultSuffix
		if isWellFormed(plain) { return plain }
		var stem = String.UnicodeScalarView()
		for scalar in vmName.decomposedStringWithCanonicalMapping.unicodeScalars {
			if scalar.properties.generalCategory == .nonspacingMark { continue }
			if isAliasCharacter(scalar) {
				stem.append(scalar)
			} else if stem.last != "-" {
				stem.append("-")
			}
		}
		let trimmed = String(stem).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
		return (trimmed.isEmpty ? "vm-" + fnv1a32(vmName) : trimmed) + defaultSuffix
	}

	// FNV-1a, 32 bit, as 8 hex digits: short, stable across runs and platforms.
	private static func fnv1a32(_ string: String) -> String {
		var hash: UInt32 = 0x811c_9dc5
		for byte in string.utf8 {
			hash ^= UInt32(byte)
			hash = hash &* 0x0100_0193
		}
		return String(format: "%08x", hash)
	}
}

// Values the guest reports through its writable drop-box. They are claims, and some of them
// end up in ~/.ssh, so each must have the shape of what it claims to be.
public enum GuestValueRule {
	// The guest script's valid_username: [A-Za-z0-9._-], not starting with "-".
	public static func isUserName(_ value: String) -> Bool {
		guard let first = value.unicodeScalars.first, first != "-" else { return false }
		return value.unicodeScalars.allSatisfy(SSHAliasRule.isAliasCharacter)
	}

	// An IPv4 or IPv6 literal, nothing else (no host name, and no zone: Darwin's inet_pton
	// accepts "fe80::1%en0", so the charset is checked first).
	public static func isAddress(_ value: String) -> Bool {
		let literal = value.unicodeScalars.allSatisfy {
			("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
				|| $0 == "." || $0 == ":"
		}
		guard literal else { return false }
		var v4 = in_addr()
		var v6 = in6_addr()
		return value.withCString { text in
			inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
		}
	}

	// "<type> <base64> [comment]": a key type such as ssh-ed25519 or
	// sk-ssh-ed25519@openssh.com, then the blob. Rules out authorized_keys options
	// (command="…" …) and known_hosts markers (@revoked …).
	public static func isPublicKeyLine(_ value: String) -> Bool {
		guard !NameRule.hasControlCharacters(value) else { return false }
		let fields = value.split(separator: " ")
		guard fields.count >= 2,
			let first = fields[0].unicodeScalars.first,
			SSHAliasRule.isASCIILetterOrDigit(first)
		else { return false }
		let typeOK = fields[0].unicodeScalars.allSatisfy {
			SSHAliasRule.isAliasCharacter($0) || $0 == "@"
		}
		let blobOK = fields[1].unicodeScalars.allSatisfy {
			SSHAliasRule.isASCIILetterOrDigit($0) || $0 == "+" || $0 == "/" || $0 == "="
		}
		return typeOK && blobOK
	}
}
