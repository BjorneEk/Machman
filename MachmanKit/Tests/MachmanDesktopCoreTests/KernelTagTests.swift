//
//  KernelTagTests.swift
//  MachmanDesktopCoreTests
//
//  The tag a kernel file is promoted under (D35): every add path suggested
//  URL.deletingPathExtension's name, which cut Debian's versioned names at their first
//  dot-number, so two kernels of one series shared a tag and drew as two identical rows.
//

import Testing
import Foundation
@testable import MachmanDesktopCore

// L1: unit.
struct KernelTagTests {
	@Test("D35: a kernel's suggested tag keeps its version and drops only packing suffixes")
	func suggestedTags() {
		let cases: [(String, String)] = [
			("/boot/vmlinuz-6.1.0-18-arm64", "vmlinuz-6.1.0-18-arm64"),
			("/boot/vmlinuz-6.1.0-21-arm64", "vmlinuz-6.1.0-21-arm64"),
			("/boot/initrd.img-6.1.0-18-arm64", "initrd.img-6.1.0-18-arm64"),
			("/boot/vmlinuz-lts", "vmlinuz-lts"),
			("/boot/initramfs-lts", "initramfs-lts"),
			("/boot/vmlinuz-6.8.5-301.fc40.aarch64", "vmlinuz-6.8.5-301.fc40.aarch64"),
			("/Users/demo/Downloads/Image", "Image"),
			("/Users/demo/Downloads/Image.gz", "Image"),
			("/Users/demo/Downloads/initrd.img", "initrd"),
			("/Users/demo/Downloads/initramfs.cpio.gz", "initramfs"),
			("/Users/demo/Downloads/linux.EFI", "linux"),
			("/Users/demo/.hidden.img", "hidden"),
			("/Users/demo/.img", "img"),
		]
		for (path, tag) in cases {
			#expect(KernelTag.suggested(forFile: path) == tag, "\(path)")
		}
	}
}
