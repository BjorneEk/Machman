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
		if let taken = Self.diskNameProblem(trimmed, on: vm) { return taken }
		if sizeText.trimmingCharacters(in: .whitespaces).isEmpty {
			return "Enter a size in GB"
		}
		guard let bytes = Self.newDiskBytes(sizeText) else {
			return "Enter a size like 64 or 1.5 GB"
		}
		if let free = capabilities?.freeDiskBytes, bytes > free {
			return "Only \(ByteSize.display(free)) is free"
		}
		return nil
	}

	// Storage disk names are unique per VM (decision 5): the one check New Disk and a disk's
	// Name field share. `except` is the disk being renamed, whose own name is no clash.
	static func diskNameProblem(
		_ name: String, on vm: VMInfo, except diskID: String? = nil
	) -> String? {
		let taken = vm.disks.contains { $0.type == .storage && $0.id != diskID && $0.name == name }
		return taken ? "This VM already has a disk named \u{201C}\(name)\u{201D}" : nil
	}

	// Sends the disk the form shows as valid; false (nothing sent) while it has a problem.
	@discardableResult
	public func createDisk(on vm: VMInfo, name: String, sizeText: String) -> Bool {
		guard newDiskProblem(on: vm, name: name, sizeText: sizeText) == nil,
			let bytes = Self.newDiskBytes(sizeText) else { return false }
		addDisk(vm.name, .storage(name: NameRule.diskName.trimmed(name), sizeBytes: bytes))
		return true
	}

	// MARK: - VM names

	// Why a VM name typed into a sheet (Duplicate, Save as New VM) or the rename field
	// can't be used, or nil. Checked trimmed: the form sends it trimmed, and the daemon
	// refuses edge spaces rather than trimming (the router keys on the name as sent).
	public func newVMNameProblem(_ raw: String) -> String? {
		let name = NameRule.vmName.trimmed(raw)
		if let problem = NameRule.vmName.problem(name) { return problem }
		return hasVM(name) ? "A VM named \u{201C}\(name)\u{201D} already exists" : nil
	}

	// Duplicate…'s button: false (nothing sent) while the name has a problem. mountIDs nil
	// carries every mount (copyMountIDs).
	@discardableResult
	public func submitCopy(
		_ vm: VMInfo, name raw: String, diskIDs: [String], mountIDs: [String]? = nil
	) -> Bool {
		guard newVMNameProblem(raw) == nil else { return false }
		copyVM(
			vm.name, newName: NameRule.vmName.trimmed(raw), diskIDs: diskIDs,
			mountIDs: mountIDs)
		return true
	}

	// Save as New VM's button, the same way.
	@discardableResult
	public func submitSafeSave(_ vm: VMInfo, name raw: String) -> Bool {
		guard newVMNameProblem(raw) == nil else { return false }
		safeSave(vm.name, to: NameRule.vmName.trimmed(raw))
		return true
	}

	// What those two sheets suggest: the first free numbered name.
	public func defaultCopyName(for name: String) -> String {
		UniqueName.numbered("\(name) copy") { hasVM($0) }
	}

	public func defaultSafeSaveName(for name: String) -> String {
		UniqueName.numbered("\(name) saved") { hasVM($0) }
	}

	// MARK: - SSH alias

	// Why the alias field's draft can't be sent, or nil. Empty means "back to the default".
	// Uniqueness is checked against the served aliases; the daemon checks again.
	public func sshAliasProblem(_ draft: String, for vm: VMInfo) -> String? {
		let alias = draft.trimmingCharacters(in: .whitespaces)
		guard !alias.isEmpty else { return nil }
		if let problem = SSHAliasRule.problem(alias) { return problem }
		if let other = vms.first(where: { $0.name != vm.name && $0.ssh?.alias == alias }) {
			return "\(other.name) already answers to \u{201C}\(alias)\u{201D}"
		}
		return nil
	}

	// The alias field's Return: false (nothing sent, the draft stays) while it has a problem.
	@discardableResult
	public func submitSSHAlias(_ vm: VMInfo, draft: String) -> Bool {
		guard sshAliasProblem(draft, for: vm) == nil else { return false }
		setSSHAlias(vm.name, alias: draft.trimmingCharacters(in: .whitespaces))
		return true
	}
}
