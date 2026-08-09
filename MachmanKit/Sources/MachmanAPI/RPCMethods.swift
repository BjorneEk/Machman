//
//  RPCMethods.swift
//  MachmanAPI
//
//  The method table of the Machman protocol plus every method's param/result shape. These
//  names and shapes are wire contract — extend, don't change.
//

import Foundation

public enum RPCMethod: String, Sendable {
	case hello = "machman.hello"
	case hostCapabilities = "host.capabilities"
	case vmList = "vm.list"
	case vmGet = "vm.get"
	case vmCreate = "vm.create"
	case vmDelete = "vm.delete"
	case vmRename = "vm.rename"
	case vmCopy = "vm.copy"
	case setHardware = "vm.setHardware"
	case regenerateMAC = "vm.regenerateMAC"
	case diskAdd = "vm.disk.add"
	case diskRemove = "vm.disk.remove"
	case mountAdd = "vm.mount.add"
	case mountRemove = "vm.mount.remove"
	case setKernelBoot = "vm.boot.setKernel"
	case updateKernelSettings = "vm.boot.kernelSettings"
	case setStartPolicy = "vm.setStartPolicy"
	case setSafety = "vm.setSafety"
	case start = "vm.start"
	case stop = "vm.stop"
	case safeSave = "vm.safeSave"
	case consoleOpen = "vm.console.open"
	case consoleClose = "vm.console.close"
	case consoleInfo = "vm.console.info"
	case preview = "vm.preview"
	case installStart = "vm.install.start"
	case installCancel = "vm.install.cancel"
	case installPhase = "vm.install.phase"
	case eventsSubscribe = "events.subscribe"
	case daemonRetire = "daemon.retire"
	// Server -> client notification carrying a VMEvent as params.
	case event = "event"
}

public enum RPCParams {
	public struct Hello: Codable, Equatable, Sendable {
		public var client: String

		public init(client: String) {
			self.client = client
		}
	}

	public struct Name: Codable, Equatable, Sendable {
		public var name: String

		public init(name: String) {
			self.name = name
		}
	}

	public struct Rename: Codable, Equatable, Sendable {
		public var name: String
		public var newName: String

		public init(name: String, newName: String) {
			self.name = name
			self.newName = newName
		}
	}

	public struct Copy: Codable, Equatable, Sendable {
		public var name: String
		public var newName: String?
		public var diskIDs: [String]?
		public var regenerateMAC: Bool?

		public init(name: String, newName: String?, diskIDs: [String]?, regenerateMAC: Bool?) {
			self.name = name
			self.newName = newName
			self.diskIDs = diskIDs
			self.regenerateMAC = regenerateMAC
		}
	}

	public struct SetHardware: Codable, Equatable, Sendable {
		public var name: String
		public var cpuCount: Int?
		public var memoryBytes: UInt64?

		public init(name: String, cpuCount: Int?, memoryBytes: UInt64?) {
			self.name = name
			self.cpuCount = cpuCount
			self.memoryBytes = memoryBytes
		}
	}

	public struct AddDisk: Codable, Equatable, Sendable {
		public var name: String
		public var disk: NewDisk

		public init(name: String, disk: NewDisk) {
			self.name = name
			self.disk = disk
		}
	}

	public struct RemoveDisk: Codable, Equatable, Sendable {
		public var name: String
		public var diskID: String

		public init(name: String, diskID: String) {
			self.name = name
			self.diskID = diskID
		}
	}

	public struct AddMount: Codable, Equatable, Sendable {
		public var name: String
		public var path: String
		public var tag: String

		public init(name: String, path: String, tag: String) {
			self.name = name
			self.path = path
			self.tag = tag
		}
	}

	public struct RemoveMount: Codable, Equatable, Sendable {
		public var name: String
		public var mountID: String

		public init(name: String, mountID: String) {
			self.name = name
			self.mountID = mountID
		}
	}

	public struct SetKernelBoot: Codable, Equatable, Sendable {
		public var name: String
		public var enabled: Bool

		public init(name: String, enabled: Bool) {
			self.name = name
			self.enabled = enabled
		}
	}

	public struct UpdateKernelSettings: Codable, Equatable, Sendable {
		public var name: String
		public var settings: KernelSettings

		public init(name: String, settings: KernelSettings) {
			self.name = name
			self.settings = settings
		}
	}

	public struct SetStartPolicy: Codable, Equatable, Sendable {
		public var name: String
		public var policy: StartPolicy

		public init(name: String, policy: StartPolicy) {
			self.name = name
			self.policy = policy
		}
	}

	public struct SetSafety: Codable, Equatable, Sendable {
		public var name: String
		public var disks: [String: Bool]?
		public var mounts: [String: Bool]?

		public init(name: String, disks: [String: Bool]?, mounts: [String: Bool]?) {
			self.name = name
			self.disks = disks
			self.mounts = mounts
		}
	}

	public struct Start: Codable, Equatable, Sendable {
		public var name: String
		public var options: StartOptions?

		public init(name: String, options: StartOptions?) {
			self.name = name
			self.options = options
		}
	}

	public struct Stop: Codable, Equatable, Sendable {
		public var name: String
		public var mode: StopMode

		public init(name: String, mode: StopMode) {
			self.name = name
			self.mode = mode
		}
	}

	public struct Preview: Codable, Equatable, Sendable {
		public var name: String
		public var maxWidth: Int?

		public init(name: String, maxWidth: Int?) {
			self.name = name
			self.maxWidth = maxWidth
		}
	}

	public struct InstallStart: Codable, Equatable, Sendable {
		public var name: String
		public var source: InstallSource

		public init(name: String, source: InstallSource) {
			self.name = name
			self.source = source
		}
	}
}

public enum RPCResults {
	public struct Hello: Codable, Equatable, Sendable {
		public var apiVersion: Int
		public var daemonVersion: String

		public init(apiVersion: Int, daemonVersion: String) {
			self.apiVersion = apiVersion
			self.daemonVersion = daemonVersion
		}
	}

	// vm.preview: null result when no preview is available; jpegBase64 otherwise.
	public struct Preview: Codable, Equatable, Sendable {
		public var jpegBase64: String

		public init(jpegBase64: String) {
			self.jpegBase64 = jpegBase64
		}
	}
}

public enum MachmanProtocol {
	public static let apiVersion = 1
}
