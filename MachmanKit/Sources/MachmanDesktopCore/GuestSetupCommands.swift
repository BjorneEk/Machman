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

	// MARK: - macOS 12 (no automount: the share mounted by hand in the user's home)

	// The mkdir stays the user's — escalated, it would leave a root-owned folder in their
	// home — and the mount takes `escalation`, so the line works whether or not the guest
	// lets a user mount. Both guides show this one line (the mount guide as is).
	public static func macOS12MountShare(_ escalation: GuestEscalation = .sudo) -> String {
		"mkdir -p \(ConsoleLoginInstallerInfo.fallbackMountPoint) && "
			+ escalation.apply(ConsoleLoginInstallerInfo.fallbackMount)
	}

	// …then the installer from it, with the same escalation (the Guest Setup guide).
	public static func macOS12MountShareAndRun(_ escalation: GuestEscalation = .sudo) -> String {
		macOS12MountShare(escalation) + " && " + escalation.apply(
			GuestSetupInstallerInfo.runCommand(
				inShareAt: ConsoleLoginInstallerInfo.fallbackMountPoint))
	}

	// MARK: - The guide's BSD bootstrap (unescalated: the page's choice escalates them)

	// FreeBSD's fuse driver, loaded unless it already is.
	public static let bsdFuseLoad = "kldstat -q -m fusefs || kldload fusefs"

	// Mounts Machman's setup folder over sshfs at the share's guest path. With the guest's
	// key approved it goes through the user's 'mac' alias — root reads ~root/.ssh/config, so
	// -F brings the user's in (key and pinned host key, no password); otherwise it asks for
	// the Mac account's password once. The host path is quoted: it can carry the VM's name.
	public static func bsdShareMount(
		approvedGuestUser: String?, hostUser: String, hostAddress: String, sharePath: String
	) -> String {
		let mountPoint = GuestPaths.share
		let options = "-o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3"
		let path = ShellQuote.single(sharePath)
		guard let user = approvedGuestUser else {
			return "mkdir -p \(mountPoint) && sshfs \(hostUser)@\(hostAddress):\(path) "
				+ "\(mountPoint) \(options)"
		}
		return "mkdir -p \(mountPoint) && sshfs -F /home/\(user)/.ssh/config "
			+ "mac:\(path) \(mountPoint) \(options)"
	}
}
