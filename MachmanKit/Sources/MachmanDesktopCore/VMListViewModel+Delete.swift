//
//  VMListViewModel+Delete.swift
//  MachmanDesktopCore
//
//  Delete VM…'s question (X7: one sentence; the title names the VM, so the message doesn't).
//  The window's confirmationDialog shows it; a test can pin it here.
//

import Foundation

extension VMListViewModel {
	public static func deleteVMTitle(_ name: String) -> String {
		"Delete \u{201C}\(name)\u{201D}?"
	}

	public static let deleteVMMessage = "The VM and the files it owns are deleted permanently."
}
