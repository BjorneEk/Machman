//
//  GuestSetupCommands.swift
//  MachmanDesktopCore
//
//  The guest commands the desktop offers to copy — the Guest Setup inspector's run line, the
//  mount inspector's mount line, the Setup Guide's steps — built in one place so the surfaces
//  can't disagree (H12, H13). A command that needs root carries the guest family's
//  escalation on EVERY command of a chain: "sudo a && b" would run b as the user, and
//  "sudo a || b" would run the fallback as the user. Pure text, like SSHCommand.
//

import Foundation
import MachmanAPI

// How a command gets root in a guest.
public enum GuestEscalation: String, CaseIterable, Identifiable, Sendable {
	case sudo, doas, root

	public var id: String { rawValue }
	public var label: String { rawValue }
	public var prefix: String { self == .root ? "" : rawValue + " " }

	// `command` with the prefix before each of its commands (split on " && " and " || ",
	// the separators kept). Root changes nothing.
	public func apply(_ command: String) -> String {
		guard !prefix.isEmpty else { return command }
		var out = prefix
		var rest = command[...]
		while let separator = [" && ", " || "]
			.compactMap({ rest.range(of: $0) })
			.min(by: { $0.lowerBound < $1.lowerBound }) {
			out += rest[..<separator.upperBound] + prefix
			rest = rest[separator.upperBound...]
		}
		return out + rest
	}
}

public enum GuestSetupCommands {
	public enum Family: Sendable {
		case linux, bsd, macOS
	}

	// The escalations a family's guests offer, the usual one first: most Linux ships sudo,
	// OpenBSD ships doas (FreeBSD base neither — root is the way there), macOS has no doas.
	public static func escalations(for family: Family) -> [GuestEscalation] {
		switch family {
		case .linux: return [.sudo, .doas, .root]
		case .bsd: return [.doas, .sudo, .root]
		case .macOS: return [.sudo, .root]
		}
	}

	// The installer's run line with the family's usual escalation. A Linux guest whose share
	// doesn't automount mounts it first; a BSD guest has it over sshfs by then, and a macOS
	// guest's share automounts.
	public static func run(_ family: Family, shareMounted: Bool) -> String {
		let escalation = escalations(for: family)[0]
		switch family {
		case .macOS:
			return escalation.apply(GuestSetupInstallerInfo.runFromAutomountCommand)
		case .linux where !shareMounted:
			return escalation.apply(
				GuestPaths.mountShareCommand + " && " + GuestSetupInstallerInfo.runCommand())
		case .linux, .bsd:
			return escalation.apply(GuestSetupInstallerInfo.runCommand())
		}
	}

	// Mounting the share by hand, with the family's usual escalation.
	public static func mountShare(_ family: Family) -> String {
		escalations(for: family)[0].apply(GuestPaths.mountShareCommand)
	}
}
