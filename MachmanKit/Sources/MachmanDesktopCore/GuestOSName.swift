//
//  GuestOSName.swift
//  MachmanDesktopCore
//
//  A guest OS as a person reads it. Guest Setup reports /etc/os-release's ID ("debian",
//  "opensuse-tumbleweed") or the kernel's name ("freebsd", "darwin"): raw ids never reach a
//  label (wording rule 6, W6), so a known one reads as its own name and any other as "Guest".
//

import Foundation

public enum GuestOSName {
	// The guest OSes Machman aims at (decision 2), by the id the guest reports.
	static let names: [String: String] = [
		"debian": "Debian", "ubuntu": "Ubuntu", "fedora": "Fedora", "arch": "Arch Linux",
		"alpine": "Alpine", "nixos": "NixOS", "void": "Void Linux", "devuan": "Devuan",
		"gentoo": "Gentoo", "rhel": "Red Hat Enterprise Linux", "centos": "CentOS",
		"rocky": "Rocky Linux", "almalinux": "AlmaLinux", "kali": "Kali Linux",
		"linuxmint": "Linux Mint", "freebsd": "FreeBSD", "openbsd": "OpenBSD",
		"netbsd": "NetBSD", "darwin": "macOS", "macos": "macOS",
	]

	// "Debian" for "debian"; openSUSE's ids all read "openSUSE"; nil or unknown reads "Guest".
	public static func display(_ id: String?) -> String {
		guard let id = id?.lowercased(), !id.isEmpty else { return "Guest" }
		if id == "opensuse" || id.hasPrefix("opensuse-") { return "openSUSE" }
		return names[id] ?? "Guest"
	}
}
