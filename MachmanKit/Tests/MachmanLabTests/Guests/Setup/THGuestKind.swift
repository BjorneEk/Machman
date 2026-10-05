//
//  THGuestKind.swift
//  MachmanLabTests
//
//  The guests r3-th's Guest Setup rows run on: the prepared Debian (systemd), Debian-sysv and
//  Alpine disks under VZ through the lab agent, FreeBSD 14/15 under QEMU (beside a running
//  "carrier" VZ VM whose share they mount over sshfs), and the spike images.
//

import Foundation
import MachmanAPI
import MachmanDesktopCore
import Testing

enum THGuestKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
	case debian
	case debianSysv = "debian-sysv"
	case alpine = "alpine-disk"
	case freebsd14
	case freebsd15
	case vzfreebsd
	case openbsd
	case netbsd

	var testDescription: String { rawValue }

	/// The guide's family: the escalation a copied command leads with.
	var family: GuestSetupCommands.Family {
		switch self {
		case .debian, .debianSysv, .alpine: .linux
		default: .bsd
		}
	}

	/// The family's usual escalation (sudo on Linux, doas on the BSDs).
	var escalation: GuestEscalation { GuestSetupCommands.escalations(for: family)[0] }

	/// Whether the guest is a Machman VM of the lab agent (else QEMU beside a carrier).
	var isVZ: Bool {
		switch self {
		case .debian, .debianSysv, .alpine, .vzfreebsd: true
		default: false
		}
	}

	var isLinux: Bool { family == .linux }

	/// r3-td's prepared image, where the guest is one.
	var labGuest: LabGuest? {
		switch self {
		case .debian: .debian
		case .debianSysv: .debianSysv
		case .freebsd14: .freebsd14
		case .freebsd15: .freebsd15
		default: nil
		}
	}

	/// A short VM name stem.
	var stem: String {
		switch self {
		case .debian: "deb"
		case .debianSysv: "debsysv"
		case .alpine: "alp"
		case .freebsd14: "fb14"
		case .freebsd15: "fb15"
		case .vzfreebsd: "vzfb"
		case .openbsd: "obsd"
		case .netbsd: "nbsd"
		}
	}

	/// The installer's state file in this guest.
	var stateFile: String {
		(isLinux ? GuestPaths.stateDirLinux : GuestPaths.stateDirBSD) + "/"
			+ GuestPaths.stateFileName
	}

	/// /etc/os-release's ID (Linux) or uname's name, lower-cased, as the report's OS_ID.
	var osID: String {
		switch self {
		case .debian, .debianSysv: "debian"
		case .alpine: "alpine"
		case .freebsd14, .freebsd15, .vzfreebsd: "freebsd"
		case .openbsd: "openbsd"
		case .netbsd: "netbsd"
		}
	}

	/// The init the installer detects.
	var initName: String {
		switch self {
		case .debian: "systemd"
		case .debianSysv: "inittab"
		case .alpine: "openrc"
		case .freebsd14, .freebsd15, .vzfreebsd: "freebsd-rc"
		case .openbsd: "openbsd-rc"
		case .netbsd: "netbsd-rc"
		}
	}

	/// The package manager the installer prefers.
	var packageManager: String {
		switch self {
		case .debian, .debianSysv: "apt"
		case .alpine: "apk"
		case .freebsd14, .freebsd15, .vzfreebsd: "pkg"
		case .openbsd: "pkg_add"
		case .netbsd: "pkgin"
		}
	}

	/// The prepared image of a VZ Linux guest (prepared on a miss inside the lab run).
	func imagePath() async throws -> String {
		if let labGuest { return try await labGuest.imagePath() }
		if self == .alpine {
			let output = try await LabScripts.check(
				LabScripts.prepare, ["path", rawValue], timeout: 1800)
			return LabScripts.lastLine(output)
		}
		throw LabError.specInvalid("\(rawValue) has no prepared VZ image")
	}
}
