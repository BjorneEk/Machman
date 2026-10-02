//
//  VMListViewModel+NewMac.swift
//  MachmanDesktopCore
//
//  The New VM picker's macOS template (H21, decision 15): it opens straight into the Install
//  macOS flow. Nothing is created until a source is picked; then the VM is made from the mac
//  template, selected, and its install starts — no EFI VM left waiting for Bootloader ▸
//  macOS…, and a cancelled pick leaves no stray VM.
//

import Foundation
import MachmanAPI

extension VMListViewModel {
	public func createMacVM(source: InstallSource) async {
		guard let name = await createVM(template: .mac) else { return }
		select(name: name)
		startInstall(name, source: source)
	}
}
