//
//  Samples+Messages.swift
//  MachmanFixtures
//
//  Engine messages as wave 4 words them (lane 4c): what a failed macOS install stores, a
//  boot-time warning, a refused import. Each is the engine's text word for word, so tests and
//  renders show what a person reads.
//

import Foundation
import MachmanAPI

extension Samples {
	// A macOS guest whose install failed, with the reason MacInstaller stores now for
	// macOSFailedInstall's error: its description plus its separate failure reason (H31).
	// macOSFailedInstall keeps the old dump, which an older daemon still stores.
	public static func macOSFailedInstallReadable(_ name: String = "Sequoia") -> VMInfo {
		var vm = macOS(name)
		vm.boot.macInstallState = MacInstallState(
			kind: .failed,
			message: "Installation failed. A software update is required to complete the "
				+ "installation.")
		return vm
	}

	// A boot-time warning as the engine words it now: one sentence, without the VM's name
	// (the desktop shows "<VM>: …"), from VMDevices.resolvedDevices.
	public static let bootWarning =
		"The Mac trackpad needs a macOS guest, so it isn’t attached."

	// The same kind of warning from a 1.0.12 daemon, which started with the VM's name.
	public static func olderDaemonBootWarning(_ vm: String) -> String {
		"\(vm) has no display device \u{2014} started headless"
	}
}
