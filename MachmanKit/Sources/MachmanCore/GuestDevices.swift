//
//  GuestDevices.swift
//  MachmanCore
//
//  Persisted guest-device config (wire 1.0.4). A VM's `devices` array in its on-disk config
//  declares which devices the engine attaches at start; configs predating the key get the
//  implied per-boot set synthesized at load (presence-sentinel migration, like the serial
//  ports). Kind is a plain string on disk so a config written by a NEWER daemon keeps its
//  unknown kinds verbatim through an older-1.0.4+ daemon's load/save cycle.
//

import Foundation
import MachmanAPI

struct GuestDevice: Codable, Equatable, Identifiable {
	var kind: String
	var enabled: Bool = true
	// Flat per-kind settings (VMDiskKind lesson: never an enum with associated values).
	var displayWidthPixels: Int?
	var displayHeightPixels: Int?
	var displayPixelsPerInch: Int?
	var sharesClipboard: Bool?

	var id: String { kind }
	var deviceKind: DeviceKind { DeviceKind(rawValue: kind) ?? .unknown }

	init(kind: DeviceKind) {
		self.kind = kind.rawValue
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case enabled
		case displayWidthPixels
		case displayHeightPixels
		case displayPixelsPerInch
		case sharesClipboard
	}

	// Tolerant decode: absent enabled defaults true; unknown kinds are preserved verbatim.
	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.kind = try c.decode(String.self, forKey: .kind)
		self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
		self.displayWidthPixels = try c.decodeIfPresent(Int.self, forKey: .displayWidthPixels)
		self.displayHeightPixels =
			try c.decodeIfPresent(Int.self, forKey: .displayHeightPixels)
		self.displayPixelsPerInch =
			try c.decodeIfPresent(Int.self, forKey: .displayPixelsPerInch)
		self.sharesClipboard = try c.decodeIfPresent(Bool.self, forKey: .sharesClipboard)
	}
}

// A per-kernel-file command-line override (vm.kernel.setOverride). Persisted in VMConfig
// keyed by the file's VM-relative identity "role/tag/fileName" — stable across VM renames
// and library relocation, unlike the absolute path the wire uses to address files.
struct KernelOverrideConfig: Codable, Equatable {
	var commandLine: String
	var enabled: Bool
}

extension VMConfig {
	// The device set a config gets when its file predates the devices key — exactly what the
	// engine attached unconditionally before devices became configurable. Shared vocabulary
	// with clients via MachmanAPI.ImpliedDevices.
	static func impliedDevices(for boot: BootConfig) -> [GuestDevice] {
		let macGuest = if case .macOS = boot { true } else { false }
		return ImpliedDevices.kinds(macGuest: macGuest).map(GuestDevice.init)
	}

	// The wire addresses kernel overrides by absolute file path; the config keys them by the
	// stable VM-relative identity.
	static func kernelOverrideKey(for file: OwnedKernelFile) -> String {
		"\(file.role.rawValue)/\(file.tag)/\(file.fileName)"
	}
}
