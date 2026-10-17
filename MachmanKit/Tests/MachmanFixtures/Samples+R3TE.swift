//
//  Samples+R3TE.swift
//  MachmanFixtures
//
//  Wave r3t, lane r3-te: the states the manual rows' L1 tests read that the other samples
//  don't reach — start policies, a VM without a display, sshfs before and after the
//  guest → Mac approval, setup reports from none to a partial run, and SSH that gave up.
//

import Foundation
import MachmanAPI

extension Samples {
	// A stopped Linux guest that starts at login (a per-VM launchd job).
	public static func linuxAutostart(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.startPolicy = StartPolicy(autostart: true)
		return vm
	}

	// A stopped Linux guest whose plain Start runs safe.
	public static func linuxSafePolicy(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.startPolicy = StartPolicy(safe: true)
		return vm
	}

	// A stopped Linux guest whose plain Start runs headless and safe.
	public static func linuxHeadlessSafePolicy(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.startPolicy = StartPolicy(windowed: false, safe: true)
		return vm
	}

	// A Linux guest whose display device is disabled: no window can open, so none is.
	public static func linuxNoDisplay(
		_ name: String = "Debian", state: VMState = .running
	) -> VMInfo {
		var vm = linux(name, state: state)
		vm.devices = vm.devices?.map { device in
			guard device.kind == .graphics else { return device }
			var graphics = device
			graphics.enabled = false
			return graphics
		}
		vm.windowOpen = false
		return vm
	}

	// A Linux guest with sshfs installed, its guest → Mac key in `reverse`: mounting host
	// folders over sshfs needs that key approved.
	public static func linuxSSHFS(
		_ reverse: SSHInfo.ReverseState, _ name: String = "Debian"
	) -> VMInfo {
		var vm = linuxReverse(reverse, name)
		vm.ssh?.sshfsAvailable = true
		return vm
	}

	// A Linux guest with Guest Setup attached that never ran in the guest: no report.
	public static func setupNotInstalled(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name)
		vm.setup = GuestSetupInfo(
			installed: false, currentScriptVersion: 3, scripts: setupScripts(),
			servedScript: setupScriptLatest.id)
		vm.ssh = nil
		return vm
	}

	// A running Linux guest whose last setup run applied some steps and failed one, with
	// the feature list such a report carries: what works, what isn't set up yet, and the
	// kernel console the guest can't have.
	public static func partialSetupRun(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.setup?.lastRunStatus = GuestRunStatus.partial
		vm.setup?.errors = [
			GuestSetupError(step: "sshfs", message: "could not install the 'sshfs' package"),
		]
		vm.setup?.features = [
			GuestFeatureInfo(
				id: GuestFeature.console, available: true, configured: true, detail: "hvc0"),
			GuestFeatureInfo(id: GuestFeature.ssh, available: true, configured: true),
			GuestFeatureInfo(id: GuestFeature.sshfs, available: true, configured: false),
			GuestFeatureInfo(
				id: GuestFeature.kernelConsole, available: false,
				reason: "The guest boots through EFI, so its kernel console is GRUB's choice",
				configured: false),
		]
		return vm
	}

	// A running Linux guest whose sshd stopped answering: the daemon gave up waiting.
	public static func sshUnreachable(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.ssh?.reachability = .unreachable
		vm.ssh?.reachabilityDetail = "no answer on port 22"
		return vm
	}
}
