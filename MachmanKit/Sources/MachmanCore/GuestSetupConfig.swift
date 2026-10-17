//
//  GuestSetupConfig.swift
//  MachmanCore
//
//  Persisted guest-setup state (wire 1.0.7): what the unified installer's report taught
//  us. Absent from disk until the installer is first used (conditional encode) — and part
//  of why 1.0.7 is the version floor: an older daemon's config rewrite drops the keys it
//  does not know. Statuses and vocabularies are plain strings (the reverseState lesson);
//  the per-feature/console/automount entries persist the MachmanAPI DTOs directly — they
//  are coder-agnostic value types with tolerant decodes, so a mirror would be one more
//  lockstep site carrying nothing.
//

import Foundation
import MachmanAPI

struct GuestSetupConfig: Codable, Equatable {
	// A report is on file and the last run did not uninstall.
	var installed: Bool?
	var guestOS: String?
	var guestOSFamily: String?
	var guestOSVersion: String?
	var guestInit: String?
	var lastReportAt: Date?          // stamped by the host at ingestion
	var scriptVersion: Int?          // the script version that produced the report
	var scriptCksum: String?         // …and its POSIX cksum, "<crc> <length>" (v8; host-only)
	var lastRunStatus: String?
	var lastRunNote: String?
	var lastTransport: String?
	var errors: [GuestSetupError] = []
	var notes: [GuestSetupNote] = []
	var features: [GuestFeatureInfo] = []
	var consoles: [GuestConsoleInfo] = []
	var automounts: [GuestAutomountInfo] = []
	// The user asked for a reinstall/update: serve the installer again (vm.setup.serve).
	// nil = false; only meaningful once installed — fresh guests always serve.
	var reinstallRequested: Bool?
	// A fresh copy's source, by its marker (vm.copy): the copy's payloads say so (COPY_OF)
	// until its first report, so its first run renews the identity its disk carries — also
	// when the source's guest never ran Guest Setup. Host-only, never on the wire.
	var copyOf: String?

	init() {}

	private enum CodingKeys: String, CodingKey {
		case installed
		case guestOS
		case guestOSFamily
		case guestOSVersion
		case guestInit
		case lastReportAt
		case scriptVersion
		case scriptCksum
		case lastRunStatus
		case lastRunNote
		case lastTransport
		case errors
		case notes
		case features
		case consoles
		case automounts
		case reinstallRequested
		case copyOf
	}

	// Tolerant decode: every field optional-or-defaulted so future additions round-trip.
	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.installed = try c.decodeIfPresent(Bool.self, forKey: .installed)
		self.guestOS = try c.decodeIfPresent(String.self, forKey: .guestOS)
		self.guestOSFamily = try c.decodeIfPresent(String.self, forKey: .guestOSFamily)
		self.guestOSVersion = try c.decodeIfPresent(String.self, forKey: .guestOSVersion)
		self.guestInit = try c.decodeIfPresent(String.self, forKey: .guestInit)
		self.lastReportAt = try c.decodeIfPresent(Date.self, forKey: .lastReportAt)
		self.scriptVersion = try c.decodeIfPresent(Int.self, forKey: .scriptVersion)
		self.scriptCksum = try c.decodeIfPresent(String.self, forKey: .scriptCksum)
		self.lastRunStatus = try c.decodeIfPresent(String.self, forKey: .lastRunStatus)
		self.lastRunNote = try c.decodeIfPresent(String.self, forKey: .lastRunNote)
		self.lastTransport = try c.decodeIfPresent(String.self, forKey: .lastTransport)
		self.errors = try c.decodeIfPresent([GuestSetupError].self, forKey: .errors) ?? []
		self.notes = try c.decodeIfPresent([GuestSetupNote].self, forKey: .notes) ?? []
		self.features = try c.decodeIfPresent([GuestFeatureInfo].self, forKey: .features) ?? []
		self.consoles = try c.decodeIfPresent([GuestConsoleInfo].self, forKey: .consoles) ?? []
		self.automounts =
			try c.decodeIfPresent([GuestAutomountInfo].self, forKey: .automounts) ?? []
		self.reinstallRequested =
			try c.decodeIfPresent(Bool.self, forKey: .reinstallRequested)
		self.copyOf = try c.decodeIfPresent(String.self, forKey: .copyOf)
	}
}

extension VMConfig {
	// THE serve rule, one place: fresh guests always serve the installer; an installed
	// guest serves only while a reinstall/update is requested — or while its last run
	// failed, until a run gets through (a re-run is the user's next step). Off, the share
	// carries two empty reserved dirs — mountable, nothing inside.
	var servesSetupPayload: Bool {
		setup?.installed != true || setup?.reinstallRequested == true
			|| setup?.lastRunStatus == GuestRunStatus.failed
	}
}

extension VMConfig {
	// vm.setup.reset — forget the report state; the guest keeps what the script installed.
	// The drop-box is wiped too, so a stale report cannot re-teach what was just forgotten;
	// it regenerates empty at the next assembly while the device stays attached.
	func resetSetup() throws {
		// A copy that never reported stays one: its first run still renews its identity.
		let copyOf = setup?.copyOf
		setup = nil
		if let copyOf {
			var state = GuestSetupConfig()
			state.copyOf = copyOf
			setup = state
		}
		// Forgetting the guest includes the device names it reported for the ports.
		for index in consolePorts.indices { consolePorts[index].guestName = nil }
		for index in uartPorts.indices { uartPorts[index].guestName = nil }
		try? FileManager.default.removeItem(
			at: GuestInstallerWriter.payloadDirectory(
				named: GuestSetupInstallerInfo.reportDirectoryName, for: self))
		try saveVMConfig()
	}
}
