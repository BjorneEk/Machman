//
//  Samples+SetupScripts.swift
//  MachmanFixtures
//
//  The host's store of Guest Setup scripts as a VM's setup info lists it (S67), in the ids
//  GuestSetupStore mints: the latest build's script, an earlier build's, one the user imported
//  for Debian and one a guest changed and ran on Alpine.
//

import Foundation
import MachmanAPI

extension Samples {
	public static let setupScriptLatest = GuestSetupScriptInfo(
		id: "v3-5f1c0a9e2b7d", kind: GuestSetupScriptKind.build, version: 3, addedAt: epoch,
		latest: true)
	public static let setupScriptOlder = GuestSetupScriptInfo(
		id: "v2-a04e19c3d852", kind: GuestSetupScriptKind.build, version: 2,
		addedAt: epoch.addingTimeInterval(-30 * 86_400))
	public static let setupScriptCustom = GuestSetupScriptInfo(
		id: "custom-3c9b2e7f10a4", kind: GuestSetupScriptKind.custom, version: 3,
		label: "install-patched.sh", vm: "Debian", addedAt: epoch.addingTimeInterval(86_400))
	public static let setupScriptChanged = GuestSetupScriptInfo(
		id: "changed-7e4d1b0c9a35", kind: GuestSetupScriptKind.changed, version: 3,
		vm: "Alpine", addedAt: epoch.addingTimeInterval(2 * 86_400))

	public static func setupScripts() -> [GuestSetupScriptInfo] {
		[setupScriptLatest, setupScriptOlder, setupScriptCustom, setupScriptChanged]
	}
}
