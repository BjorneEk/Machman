//
//  InstallPhase.swift
//  MachmanAPI
//
//  Live macOS-install progress as broadcast by the daemon. Progress objects don't cross the
//  wire — snapshots do.
//

import Foundation

public struct InstallPhase: Codable, Sendable, Equatable {
	public enum Kind: String, Codable, Sendable {
		case idle
		case resolving
		case downloading
		case installing
		case installed
		case failed
		case interrupted

		public init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			self = Kind(rawValue: raw) ?? .idle
		}
	}

	public var kind: Kind
	public var version: String?
	public var build: String?
	public var message: String?              // failure reason for .failed
	public var progress: ProgressInfo?       // download or install progress, phase-dependent
	public var downloadStartedAt: Date?

	public init(
		kind: Kind, version: String? = nil, build: String? = nil, message: String? = nil,
		progress: ProgressInfo? = nil, downloadStartedAt: Date? = nil
	) {
		self.kind = kind
		self.version = version
		self.build = build
		self.message = message
		self.progress = progress
		self.downloadStartedAt = downloadStartedAt
	}
}

public struct ProgressInfo: Codable, Sendable, Equatable {
	public var fraction: Double
	public var completedBytes: Int64?
	public var totalBytes: Int64?

	public init(fraction: Double, completedBytes: Int64? = nil, totalBytes: Int64? = nil) {
		self.fraction = fraction
		self.completedBytes = completedBytes
		self.totalBytes = totalBytes
	}
}

public struct InstallSource: Codable, Sendable, Equatable {
	public enum Kind: String, Codable, Sendable {
		case latest   // newest restore image this host can install
		case ipsw     // local restore image at `path`
	}

	public var kind: Kind
	public var path: String?

	public init(kind: Kind, path: String? = nil) {
		self.kind = kind
		self.path = path
	}

	public static let latest = InstallSource(kind: .latest)
	public static func ipsw(_ path: String) -> InstallSource {
		InstallSource(kind: .ipsw, path: path)
	}
}
