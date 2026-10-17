//
//  SafeRun.swift
//  MachmanCore
//
//  The safe-run vocabulary: where shadows live, what a run root's marker says, how a VM's
//  safe flags map onto a VMCopyRequest, and the history copy-back at the end of a clean run.
//  Pure path/data helpers — the daemon's RoutingMachman orchestrates them.
//
//  A shadow is `<dataDir>/safe/run-<uuid>/<display>/…`: same volume as the library by
//  construction (promotion is one atomic rename), outside the registry scan root (never
//  listed). The vmhost is pointed at the run root and never knows it is a shadow.
//

import Foundation

// Written into the run root in two phases: intent (pid nil) before the copy, the vmhost's
// pid once the spawn returned. The pid is what the startup sweep matches against the
// adopted host's socket peer, so a crash leftover can never be mistaken for a live run.
struct ShadowMarker: Codable, Equatable {
	var vm: String
	var createdAt: Date
	var pid: Int32?
}

enum SafeRun {
	static let runPrefix = "run-"
	static let markerName = "machman-shadow.json"

	static func markerPath(runRoot: String) -> String {
		runRoot + "/" + markerName
	}

	static func readMarker(runRoot: String) -> ShadowMarker? {
		guard let data = FileManager.default.contents(atPath: markerPath(runRoot: runRoot))
		else { return nil }
		return try? JSONDecoder().decode(ShadowMarker.self, from: data)
	}

	static func writeMarker(_ marker: ShadowMarker, runRoot: String) throws {
		// Daemon-private file — plain coder, never MachmanWire.
		try JSONEncoder().encode(marker)
			.write(to: URL(fileURLWithPath: markerPath(runRoot: runRoot)), options: .atomic)
	}

	// THE policy mapping (todo:16), in one pure place: safe disks are cloned (external
	// images become owned storage — the only promotion-surviving shape), unsafe disks
	// reference the real file, ISOs always reference, safe mounts are omitted. The shadow
	// impersonates the VM: same name, same MAC, same identity files, same history.
	static func shadowRequest(
		config: VMConfig, sourceDir: String, runRoot: String,
		progress: (@Sendable (UInt64, UInt64) -> Void)? = nil
	) -> VMCopyRequest {
		var policies: [String: VMCopyRequest.DiskPolicy] = [:]
		for disk in config.disks {
			switch disk.kind {
			case .storage, .fromUrl:
				policies[disk.id] = disk.safe ? .clone : .reference
			case .iso, .unknown:
				policies[disk.id] = .reference
			}
		}
		let unsafeMounts = Set(
			config.mountPoints.filter { !$0.safe }.map { $0.id.uuidString })
		let guestKind: VMCopyRequest.GuestKind = {
			if case .macOS = config.boot { return .macOS }
			return .generic
		}()
		return VMCopyRequest(
			sourceDir: sourceDir, destinationParent: runRoot, newName: config.name,
			diskPolicies: policies, includedMountIDs: unsafeMounts,
			regenerateMAC: false, guestKind: guestKind, identity: .impersonate,
			progress: progress)
	}

	enum SweepVerdict: Equatable {
		case reattach   // the adopted host IS this shadow's vmhost — restore isSafe/shadowRoot
		case keep       // possibly alive — never delete under anything that might own it
		case delete     // provably dead leftover
	}

	// The startup-sweep decision for one run root. hostedPeerPID is the socket peer of the
	// adopted host for marker.vm (nil when that VM has no adopted host); isPidAlive is
	// injected for tests. Conservative by design: the only destructive verdicts are for
	// markers whose pid is provably dead or that never reached the pid phase with no host.
	static func sweepVerdict(
		marker: ShadowMarker?, hostedPeerPID: Int32?,
		isPidAlive: (Int32) -> Bool
	) -> SweepVerdict {
		guard let marker else { return .delete }              // unreadable = never attachable
		guard let pid = marker.pid else {
			// Died between intent and spawn — unless a host exists (it MIGHT be the one
			// whose marker rewrite was lost), in which case never delete under it.
			return hostedPeerPID == nil ? .delete : .keep
		}
		if let hostedPeerPID {
			if hostedPeerPID == pid { return .reattach }
			// A different process owns the VM's socket (e.g. an unsafe autostart run).
			return isPidAlive(pid) ? .keep : .delete
		}
		// No adopted host: a live pid is an unadopted safe vmhost — leave its disks alone.
		return isPidAlive(pid) ? .keep : .delete
	}

	// kill(pid, 0): 0 = alive; EPERM = alive but not ours (still alive).
	static func defaultPidAlive(_ pid: Int32) -> Bool {
		kill(pid, 0) == 0 || errno == EPERM
	}

	// A clean safe-run stop copies the session's history back to the real VM (user
	// decision): the shadow started FROM the real values and only added, so its lastRan and
	// total are simply authoritative. The shadow is only read; the real config is saved like
	// any save (Q39). Every failure is a silent no-op — a crash loses the session's history,
	// the same as an unsafe run killed mid-flight.
	static func absorbShadowHistory(realDir: String, shadowDir: String) {
		let shadowFolder = URL(fileURLWithPath: shadowDir)
		guard let shadow = BootGuard.peekConfig(
			name: shadowFolder.lastPathComponent,
			library: shadowFolder.deletingLastPathComponent().path)
		else { return }
		try? VMConfig.rewrite(atDir: realDir) { real in
			if let lastRan = shadow.lastRan {
				real.lastRan = lastRan
			}
			real.totalRuntimeSeconds = max(real.totalRuntimeSeconds, shadow.totalRuntimeSeconds)
		}
	}
}
