//
//  VMListViewModel+RenameFields.swift
//  MachmanDesktopCore
//
//  The inspector's rename fields (PR8): the VM name, a disk's name and a mount's tag say
//  why a draft can't be used while it is typed, in the daemon's own words, and a refusal
//  the daemon sends back shows under the field instead of as an alert. Return sends only
//  a draft the field shows as valid. The tree's rename-in-place keeps its alert: it has no
//  field left to show a reason under.
//

import Foundation
import MachmanUI
import MachmanAPI

extension VMListViewModel {
	// MARK: - Refusals

	// A refusal goes to the field that asked when it passed `refused` (logged as an alert
	// would be), else to an alert.
	func refuse(
		_ message: String, while action: String, to refused: (@MainActor (String) -> Void)?
	) {
		guard let refused else {
			present(message: message, while: action)
			return
		}
		MachmanLogger.log(.interactionError, "\(action) refused: \(message)")
		refused(message)
	}

	func refuse(
		_ error: Error, while action: String, to refused: (@MainActor (String) -> Void)?
	) {
		refuse(Self.message(for: error), while: action, to: refused)
	}

	// MARK: - VM name

	// Why the Name field's draft can't be sent, or nil — nil for the VM's own name too.
	public func vmRenameProblem(_ draft: String, for vm: VMInfo) -> String? {
		NameRule.vmName.trimmed(draft) == vm.name ? nil : newVMNameProblem(draft)
	}

	// The Name field's Return: false (nothing sent, the draft and its reason stay) while the
	// draft has a problem or the VM must stop first; an unchanged name just reverts.
	@discardableResult
	public func submitRename(
		_ vm: VMInfo, draft: String, profiles: TerminalProfileStore,
		reverted: @escaping @MainActor () -> Void = {},
		refused: @escaping @MainActor (String) -> Void
	) -> Bool {
		guard vm.refusal(.renameVM) == nil, vmRenameProblem(draft, for: vm) == nil else {
			return false
		}
		guard NameRule.vmName.trimmed(draft) != vm.name else {
			reverted()
			return false
		}
		requestRename(vm, to: draft, profiles: profiles, reverted: reverted, refused: refused)
		return true
	}

	// MARK: - Disk name

	// Why a disk's Name field draft can't be sent, or nil — nil for the disk's own name too.
	public func diskRenameProblem(_ draft: String, diskID: String, on vm: VMInfo) -> String? {
		let rule = NameRule.diskName
		let name = rule.trimmed(draft)
		guard name != vm.disks.first(where: { $0.id == diskID })?.name else { return nil }
		if let problem = rule.problem(name) { return problem }
		if vm.disks.contains(where: { $0.type == .storage && $0.id != diskID && $0.name == name }) {
			return "This VM already has a disk named \u{201C}\(name)\u{201D}"
		}
		return nil
	}

	// The disk Name field's Return: false (nothing sent) while the draft has a problem, is
	// the disk's own name, or the VM must stop first.
	@discardableResult
	public func submitDiskRename(
		_ vm: VMInfo, diskID: String, draft: String,
		refused: @escaping @MainActor (String) -> Void
	) -> Bool {
		let name = NameRule.diskName.trimmed(draft)
		guard vm.refusal(.renameDisk) == nil,
			let disk = vm.disks.first(where: { $0.id == diskID }), name != disk.name,
			diskRenameProblem(draft, diskID: diskID, on: vm) == nil
		else { return false }
		renameDisk(vm.name, diskID: diskID, newName: name, refused: refused)
		return true
	}

	// MARK: - Mount tag

	// Why a mount's Tag field draft can't be sent, or nil — nil for its own tag too.
	public func mountTagProblem(_ draft: String, mountID: String, on vm: VMInfo) -> String? {
		let rule = NameRule.mountTag
		let tag = rule.trimmed(draft)
		guard tag != vm.mounts.first(where: { $0.id == mountID })?.tag else { return nil }
		if let problem = rule.problem(tag) { return problem }
		if vm.mounts.contains(where: { $0.id != mountID && $0.tag == tag }) {
			return "This VM already has a mount tagged \u{201C}\(tag)\u{201D}"
		}
		return nil
	}

	// The Tag field's Return: false (nothing sent) while the draft has a problem or is the
	// mount's own tag.
	@discardableResult
	public func submitMountTag(
		_ vm: VMInfo, mountID: String, draft: String,
		refused: @escaping @MainActor (String) -> Void
	) -> Bool {
		let tag = NameRule.mountTag.trimmed(draft)
		guard let mount = vm.mounts.first(where: { $0.id == mountID }), tag != mount.tag,
			mountTagProblem(draft, mountID: mountID, on: vm) == nil
		else { return false }
		setMountTag(vm.name, mountID: mountID, tag: tag, refused: refused)
		return true
	}
}
