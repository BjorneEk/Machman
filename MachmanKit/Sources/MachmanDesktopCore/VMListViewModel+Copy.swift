//
//  VMListViewModel+Copy.swift
//  MachmanDesktopCore
//
//  Duplicate…'s choices beyond the name: which mounts the copy keeps (C11).
//

import Foundation
import MachmanAPI

extension VMListViewModel {
	// The mounts Duplicate… sends: nil while every mount is ticked — every mount travels,
	// the request an older daemon knows too — else the ticked ones in the VM's order.
	public nonisolated static func copyMountIDs(
		for vm: VMInfo, included: Set<String>
	) -> [String]? {
		let all = vm.mounts.map(\.id)
		guard !all.allSatisfy(included.contains) else { return nil }
		return all.filter(included.contains)
	}
}
