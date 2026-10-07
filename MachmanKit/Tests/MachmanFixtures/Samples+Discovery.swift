//
//  Samples+Discovery.swift
//  MachmanFixtures
//
//  What SSH address discovery can say about a running guest beyond its leases and the ARP
//  table (E56).
//

import Foundation
import MachmanAPI

extension Samples {
	// A running Debian guest on a static address: no lease names it, so discovery took the
	// address the guest reported.
	public static func reportedAddress(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.ssh?.address = "192.168.64.40"
		vm.ssh?.addressSource = "report"
		return vm
	}
}
