//
//  GuestPaths.swift
//  MachmanAPI
//
//  Where Machman's things live INSIDE a guest, in one place (1.0.6). These were invented
//  per call site — the setup guide, the mounts inspector, the installer script's defaults
//  — which produced two names for the share (/mnt/host-share on Linux, /mnt/machman on
//  BSD) and one name doing two jobs (the sshfs-mounted payload and the future
//  host-folder mounts both wanted /mnt/machman).
//
//  One root, so a user can see everything Machman mounted in their guest — and unmount it
//  — in one place; and ONE path for the share whatever carried it there, so the command
//  that runs the installer is the same sentence on Debian and on OpenBSD. The script gets
//  these through its machman.env, so the guest side cannot drift from the host side
//  either.
//

import Foundation

public enum GuestPaths {
	// Everything Machman mounts in a guest hangs off this.
	public static let root = "/mnt/machman"

	// Machman's share: the generated installer payloads plus the VM's host mounts.
	// Reached by virtiofs (the shareTag below) where there is a driver, and by sshfs of
	// the same directory where there is not — the guest path is the same either way.
	public static var share: String { root + "/share" }

	// Individual host folders mounted over the guest→host SSH link, for guests without a
	// virtiofs driver. Deliberately NOT the share: they are different things arriving by
	// different routes, and one directory cannot be both.
	public static var mounts: String { root + "/mounts" }

	// The virtiofs tag non-macOS guests mount.
	public static let shareTag = "host-share"

	// macOS guests mount the share themselves, at a path the OS chooses. Not ours to
	// standardize — which is exactly why it is written down here next to the ones that are.
	public static let macOSAutomount = "/Volumes/My Shared Files"

	// mkdir + mount for the guests that mount by hand. Unprivileged: what needs root is
	// the caller's decision (FreeBSD base ships neither sudo nor doas).
	public static var mountShareCommand: String {
		"mkdir -p \(share) && mount -t virtiofs \(shareTag) \(share)"
	}
}
