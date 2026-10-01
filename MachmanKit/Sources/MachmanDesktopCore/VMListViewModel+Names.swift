//
//  VMListViewModel+Names.swift
//  MachmanDesktopCore
//
//  The forms' half of the name rules (PR8): the reason a form's primary button is
//  disabled, in the daemon's own words (MachmanAPI's NameRule / SSHAliasRule), and the
//  submit that sends only what the form showed as valid. The daemon checks again at entry;
//  these exist so the user sees why before pressing anything.
//

import Foundation
import MachmanAPI

extension VMListViewModel {
	// MARK: - New Disk

	// A size field's text in bytes: a bare number is GB, decimals are fine (decision 14),
	// rounded to whole MiB. nil for anything unreadable or zero.
	public nonisolated static func newDiskBytes(_ text: String) -> UInt64? {
		guard let bytes = ByteSize.parse(text, bareUnit: .gibibyte) else { return nil }
		let rounded = ByteSize.roundToMiB(bytes)
		return rounded > 0 ? rounded : nil
	}

	// Why the New Disk form can't create yet, or nil.
	public func newDiskProblem(on vm: VMInfo, name: String, sizeText: String) -> String? {
		let rule = NameRule.diskName
		let trimmed = rule.trimmed(name)
		if let problem = rule.problem(trimmed) { return problem }
		if vm.disks.contains(where: { $0.type == .storage && $0.name == trimmed }) {
			return "This VM already has a disk named \u{201C}\(trimmed)\u{201D}"
		}
		if sizeText.trimmingCharacters(in: .whitespaces).isEmpty {
			return "Enter a size in GB"
		}
		guard let bytes = Self.newDiskBytes(sizeText) else {
			return "Enter a size in GB, like 64 or 1.5"
		}
		if let free = capabilities?.freeDiskBytes, bytes > free {
			return "Only \(ByteSize.toGB(free)) GB is free"
		}
		return nil
	}

	// Sends the disk the form shows as valid; false (nothing sent) while it has a problem.
	@discardableResult
	public func createDisk(on vm: VMInfo, name: String, sizeText: String) -> Bool {
		guard newDiskProblem(on: vm, name: name, sizeText: sizeText) == nil,
			let bytes = Self.newDiskBytes(sizeText) else { return false }
		addDisk(vm.name, .storage(name: NameRule.diskName.trimmed(name), sizeBytes: bytes))
		return true
	}
}
