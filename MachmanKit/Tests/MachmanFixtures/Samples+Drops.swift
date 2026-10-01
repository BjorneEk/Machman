//
//  Samples+Drops.swift
//  MachmanFixtures
//
//  Dragged payloads for the device tree's drop targets: file URLs that name nothing on disk,
//  so a classifier reads them by their trailing slash (`hasDirectoryPath`).
//

import Foundation

extension Samples {
	// A Finder drag of an installer ISO, a raw disk image and a source folder.
	public static func mixedDrop() -> [URL] {
		[
			URL(fileURLWithPath: "/Users/demo/Downloads/alpine-virt-3.22-aarch64.iso",
				isDirectory: false),
			URL(fileURLWithPath: "/Users/demo/VMs/scratch.raw", isDirectory: false),
			URL(fileURLWithPath: "/Users/demo/src", isDirectory: true),
		]
	}
}
