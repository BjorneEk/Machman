//
//  KernelTag.swift
//  MachmanDesktopCore
//
//  The tag a kernel or initramfs file is promoted under, suggested from its file name: the
//  picker, a drop, a paste and Promote to Owned all name it the same way.
//

import Foundation

public enum KernelTag {
	// Suffixes that say how a file is packed, not which kernel it is.
	static let packingSuffixes = [".gz", ".xz", ".zst", ".lz4", ".bz2", ".cpio", ".img", ".efi",
		".bin"]

	// The whole file name minus its packing suffixes (D35): URL.deletingPathExtension took
	// everything after the last dot, so Debian's vmlinuz-6.1.0-18-arm64 and vmlinuz-6.1.0-21-arm64
	// both became "vmlinuz-6.1" and shared one tag. A tag can't start with a dot (the name rule).
	public static func suggested(forFile path: String) -> String {
		let name = (path as NSString).lastPathComponent
		var tag = name
		while let suffix = packingSuffixes.first(where: {
			tag.lowercased().hasSuffix($0) && tag.count > $0.count
		}) {
			tag.removeLast(suffix.count)
		}
		tag = String(tag.drop { $0 == "." })
		return tag.isEmpty ? String(name.drop { $0 == "." }) : tag
	}
}
