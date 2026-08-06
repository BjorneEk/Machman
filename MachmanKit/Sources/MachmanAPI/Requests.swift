//
//  Requests.swift
//  MachmanAPI
//
//  Request payload shapes for mutating calls.
//

import Foundation

public struct NewDisk: Codable, Sendable, Equatable {
	public var type: DiskType
	public var name: String?          // .storage: image name inside the VM dir
	public var path: String?          // .image / .iso
	public var sizeBytes: UInt64?     // .storage

	public init(type: DiskType, name: String? = nil, path: String? = nil, sizeBytes: UInt64? = nil) {
		self.type = type
		self.name = name
		self.path = path
		self.sizeBytes = sizeBytes
	}

	public static func storage(name: String, sizeBytes: UInt64) -> NewDisk {
		NewDisk(type: .storage, name: name, sizeBytes: sizeBytes)
	}
	public static func image(path: String) -> NewDisk {
		NewDisk(type: .image, path: path)
	}
	public static func iso(path: String) -> NewDisk {
		NewDisk(type: .iso, path: path)
	}
}

public struct StartOptions: Codable, Sendable, Equatable {
	public var openConsole: Bool

	public init(openConsole: Bool = true) {
		self.openConsole = openConsole
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.openConsole = try c.decodeIfPresent(Bool.self, forKey: .openConsole) ?? true
	}
}

public enum StopMode: String, Codable, Sendable, Equatable {
	case soft    // ask the guest OS to shut itself down (requestStop)
	case force   // tear the VM down immediately (stop)
}
