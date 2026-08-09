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
			case .iso:
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

	// A clean safe-run stop copies the session's history back to the real VM (user
	// decision): the shadow started FROM the real values and only added, so its lastRan and
	// total are simply authoritative. Every failure is a silent no-op — a crash loses the
	// session's history, the same as an unsafe run killed mid-flight.
	static func absorbShadowHistory(realConfigPath: String, shadowConfigPath: String) {
		let fm = FileManager.default
		guard let shadowData = fm.contents(atPath: shadowConfigPath),
			let realData = fm.contents(atPath: realConfigPath),
			let shadow = try? JSONDecoder().decode(VMConfig.self, from: shadowData),
			let real = try? JSONDecoder().decode(VMConfig.self, from: realData)
		else { return }
		if let lastRan = shadow.lastRan {
			real.lastRan = lastRan
		}
		real.totalRuntimeSeconds = max(real.totalRuntimeSeconds, shadow.totalRuntimeSeconds)
		let encoder = JSONEncoder()
		encoder.outputFormatting = .prettyPrinted
		guard let encoded = try? encoder.encode(real) else { return }
		try? encoded.write(to: URL(fileURLWithPath: realConfigPath), options: .atomic)
	}
}
