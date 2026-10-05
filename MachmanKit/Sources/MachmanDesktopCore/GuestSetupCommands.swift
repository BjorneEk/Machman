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

	// `line` with the prefix before each of its commands. Root changes nothing.
	public func apply(_ line: GuestCommand) -> String {
		line.text(prefix: prefix)
	}
}

// A guest command line kept as its commands and the && / || between them, so escalation
// prefixes each command without looking for the joins in text again: split on " && ", a
// quoted path that held one got "doas " inside it (C26). Deliberately no string-literal
// conformance: an interpolated chain would quietly escalate its first command only.
public struct GuestCommand: Equatable, Sendable {
	public enum Join: String, Sendable {
		case and = " && "
		case or = " || "
	}

	private struct Link: Equatable, Sendable {
		var join: Join
		var command: String
	}

	private let first: String
	private var rest: [Link] = []

	// One command.
	public init(_ command: String) {
		first = command
	}

	// `self && next` and `self || next`, read left to right as sh reads them.
	public func and(_ next: String) -> GuestCommand { joined(.and, GuestCommand(next)) }
	public func or(_ next: String) -> GuestCommand { joined(.or, GuestCommand(next)) }
	public func and(_ next: GuestCommand) -> GuestCommand { joined(.and, next) }

	private func joined(_ join: Join, _ next: GuestCommand) -> GuestCommand {
		var line = self
		line.rest.append(Link(join: join, command: next.first))
		line.rest += next.rest
		return line
	}

	// The line with `prefix` before every command.
	func text(prefix: String) -> String {
		rest.reduce(prefix + first) { $0 + $1.join.rawValue + prefix + $1.command }
	}

	// The line as root runs it.
	public var text: String { text(prefix: "") }
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
			return escalation.apply(GuestCommand(GuestSetupInstallerInfo.runFromAutomountCommand))
		case .linux where !shareMounted:
			return escalation.apply(mountShareLine.and(GuestSetupInstallerInfo.runCommand()))
		case .linux, .bsd:
			return escalation.apply(GuestCommand(GuestSetupInstallerInfo.runCommand()))
		}
	}

	// mkdir + mount for the guests that mount the share by hand. Unescalated: what needs root
	// is the caller's decision (FreeBSD base ships neither sudo nor doas).
	public static var mountShareLine: GuestCommand {
		GuestCommand("mkdir -p \(GuestPaths.share)")
			.and("mount -t virtiofs \(GuestPaths.shareTag) \(GuestPaths.share)")
	}

	// Mounting the share by hand, with the family's usual escalation.
	public static func mountShare(_ family: Family) -> String {
		escalations(for: family)[0].apply(mountShareLine)
	}

	// MARK: - macOS 12 (no automount: the share mounted by hand in the user's home)

	// The mkdir stays the user's — escalated, it would leave a root-owned folder in their
	// home — and the mount takes `escalation`, so the line works whether or not the guest
	// lets a user mount. Both guides show this one line (the mount guide as is).
	public static func macOS12MountShare(_ escalation: GuestEscalation = .sudo) -> String {
		"mkdir -p \(ConsoleLoginInstallerInfo.fallbackMountPoint) && "
			+ escalation.apply(GuestCommand(ConsoleLoginInstallerInfo.fallbackMount))
	}

	// …then the installer from it, with the same escalation (the Guest Setup guide).
	public static func macOS12MountShareAndRun(_ escalation: GuestEscalation = .sudo) -> String {
		macOS12MountShare(escalation) + " && " + escalation.apply(GuestCommand(
			GuestSetupInstallerInfo.runCommand(
				inShareAt: ConsoleLoginInstallerInfo.fallbackMountPoint)))
	}

	// MARK: - The guide's BSD bootstrap (unescalated: the page's choice escalates them)

	// FreeBSD's fuse driver, loaded unless it already is.
	public static let bsdFuseLoad = GuestCommand("kldstat -q -m fusefs").or("kldload fusefs")

	// Mounts Machman's setup folder over sshfs at the share's guest path. With the guest's
	// key approved it goes through the user's 'mac' alias — root reads ~root/.ssh/config, so
	// -F brings the user's in (key and pinned host key, no password); otherwise it asks for
	// the Mac account's password once. The host path is quoted (it can carry the VM's name)
	// and ends in "/": it is normally the library's rename-stable link to the share, and a
	// trailing slash makes every lookup of the mount's root resolve through the link — a
	// lookup of the bare link path would find a link, not a directory.
	public static func bsdShareMount(
		approvedGuestUser: String?, hostUser: String, hostAddress: String, sharePath: String
	) -> GuestCommand {
		let mountPoint = GuestPaths.share
		let options = "-o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3"
		let path = ShellQuote.single(sharePath.hasSuffix("/") ? sharePath : sharePath + "/")
		let mkdir = GuestCommand("mkdir -p \(mountPoint)")
		guard let user = approvedGuestUser else {
			return mkdir.and("sshfs \(hostUser)@\(hostAddress):\(path) \(mountPoint) \(options)")
		}
		return mkdir.and(
			"sshfs -F /home/\(user)/.ssh/config mac:\(path) \(mountPoint) \(options)")
	}
}
