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
	case diskImport = "vm.disk.import"
	case diskPromote = "vm.disk.promote"
	case mountAdd = "vm.mount.add"
	case mountRemove = "vm.mount.remove"
	case setKernelBoot = "vm.boot.setKernel"
	case updateKernelSettings = "vm.boot.kernelSettings"
	case kernelPromote = "vm.kernel.promote"
	case kernelDelete = "vm.kernel.delete"
	case setStartPolicy = "vm.setStartPolicy"
	case setSafety = "vm.setSafety"
	case start = "vm.start"
	case stop = "vm.stop"
	case safeSave = "vm.safeSave"
	case windowOpen = "vm.window.open"
	case windowClose = "vm.window.close"
	case consoleAdd = "vm.console.add"
	case consoleRemove = "vm.console.remove"
	case uartAdd = "vm.uart.add"
	case uartRemove = "vm.uart.remove"
	case serialSetLogging = "vm.serial.setLogging"
	case preview = "vm.preview"
	case installStart = "vm.install.start"
	case installCancel = "vm.install.cancel"
	case installPhase = "vm.install.phase"
	// 1.0.4: configurable guest devices, enabled flags, kernel overrides, resize, operations.
	case deviceAdd = "vm.device.add"
	case deviceRemove = "vm.device.remove"
	case deviceUpdate = "vm.device.update"
	case setEnabled = "vm.setEnabled"
	case kernelSetOverride = "vm.kernel.setOverride"
	case diskResize = "vm.disk.resize"
	// 1.0.4 additive: entity renames (owned storage disks, mount tags, kernel tags).
	case diskRename = "vm.disk.rename"
	case mountSetTag = "vm.mount.setTag"
	case kernelRename = "vm.kernel.rename"
	// 1.0.5: ssh autoconfiguration.
	case sshSet = "vm.ssh.set"
	case sshRefresh = "vm.ssh.refresh"
	case sshReset = "vm.ssh.reset"
	// 1.0.7: the unified guest-setup installer + mount transport kinds.
	case mountSetKind = "vm.mount.setKind"
	case setupReset = "vm.setup.reset"
	case setupServe = "vm.setup.serve"
	case hostOperations = "host.operations"
	case operationCancel = "op.cancel"
	case installRosetta = "host.installRosetta"
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
		// Wave 2 (additive): the mounts to carry, by MountInfo.id; absent = every mount. An
		// older daemon ignores the key and carries every mount.
		public var mountIDs: [String]?
		public var regenerateMAC: Bool?

		public init(
			name: String, newName: String?, diskIDs: [String]?, regenerateMAC: Bool?,
			mountIDs: [String]? = nil
		) {
			self.name = name
			self.newName = newName
			self.diskIDs = diskIDs
			self.mountIDs = mountIDs
			self.regenerateMAC = regenerateMAC
		}
	}

	public struct SetHardware: Codable, Equatable, Sendable {
		public var name: String
		public var cpuCount: Int?
		public var memoryBytes: UInt64?
		// 1.0.4: nested virtualization (EFI/kernel boots on supporting hardware).
		public var nestedVirtualization: Bool?

		public init(
			name: String, cpuCount: Int?, memoryBytes: UInt64?,
			nestedVirtualization: Bool? = nil
		) {
			self.name = name
			self.cpuCount = cpuCount
			self.memoryBytes = memoryBytes
			self.nestedVirtualization = nestedVirtualization
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

	// vm.disk.import: copy the file at `path` into the VM as an owned disk.
	public struct ImportDisk: Codable, Equatable, Sendable {
		public var name: String
		public var path: String

		public init(name: String, path: String) {
			self.name = name
			self.path = path
		}
	}

	public struct AddMount: Codable, Equatable, Sendable {
		public var name: String
		public var path: String
		public var tag: String
		// 1.0.7: a MountKind value; nil (and what older clients send) = virtiofs.
		public var kind: String?

		public init(name: String, path: String, tag: String, kind: String? = nil) {
			self.name = name
			self.path = path
			self.tag = tag
			self.kind = kind
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

	// vm.kernel.promote: copy sourcePath into <vm>/kernels/<tag>/ as an owned file and
	// point the given role's field at it.
	public struct PromoteKernel: Codable, Equatable, Sendable {
		public var name: String
		public var role: KernelRole
		public var sourcePath: String
		public var tag: String

		public init(name: String, role: KernelRole, sourcePath: String, tag: String) {
			self.name = name
			self.role = role
			self.sourcePath = sourcePath
			self.tag = tag
		}
	}

	// vm.kernel.delete: remove an owned kernel/initramfs file by its absolute path.
	public struct DeleteKernel: Codable, Equatable, Sendable {
		public var name: String
		public var path: String

		public init(name: String, path: String) {
			self.name = name
			self.path = path
		}
	}

	public struct SetSerialLogging: Codable, Equatable, Sendable {
		public var name: String
		public var kind: SerialPortKind
		public var index: Int
		public var config: SerialLogConfig

		public init(name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig) {
			self.name = name
			self.kind = kind
			self.index = index
			self.config = config
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

	// vm.create: template picks the starting device set (a VMTemplate raw value); absent/nil
	// keeps today's behavior (= "default"). Sent as params where the method previously took
	// none — old daemons ignore params they never read.
	public struct Create: Codable, Equatable, Sendable {
		public var template: String?

		public init(template: String?) {
			self.template = template
		}
	}

	// vm.device.add / vm.device.remove: one device per kind, addressed by kind.
	public struct DeviceMutation: Codable, Equatable, Sendable {
		public var name: String
		public var kind: DeviceKind

		public init(name: String, kind: DeviceKind) {
			self.name = name
			self.kind = kind
		}
	}

	// vm.device.update: settings + enabled for an existing device (unavailable is ignored).
	public struct DeviceUpdate: Codable, Equatable, Sendable {
		public var name: String
		public var device: DeviceInfo

		public init(name: String, device: DeviceInfo) {
			self.name = name
			self.device = device
		}
	}

	// vm.setup.serve: whether the share serves the installer payload. Serving is forced
	// while the user has the install surface open; off takes effect when the run ends — a
	// running guest's payload is never removed under it.
	public struct SetupServe: Codable, Equatable, Sendable {
		public var name: String
		public var serve: Bool

		public init(name: String, serve: Bool) {
			self.name = name
			self.serve = serve
		}
	}

	// vm.setEnabled: batch per-entity enabled flags (vm.setSafety twin — unknown ids/indices
	// refuse the WHOLE batch). Serial ports are addressed by their index within the family,
	// as STRING keys ("0", "1", …) — Codable would encode [Int: Bool] as a JSON array,
	// which is not obvious JSON. Devices (1.0.12+) are keyed by their kind's wire spelling;
	// an older daemon ignores the key.
	public struct SetEnabled: Codable, Equatable, Sendable {
		public var name: String
		public var disks: [String: Bool]?
		public var mounts: [String: Bool]?
		public var console: [String: Bool]?
		public var uart: [String: Bool]?
		public var devices: [String: Bool]?

		public init(
			name: String, disks: [String: Bool]? = nil, mounts: [String: Bool]? = nil,
			console: [String: Bool]? = nil, uart: [String: Bool]? = nil,
			devices: [String: Bool]? = nil
		) {
			self.name = name
			self.disks = disks
			self.mounts = mounts
			self.console = console
			self.uart = uart
			self.devices = devices
		}
	}

	// vm.kernel.setOverride: per-file command-line override for an owned kernel file.
	public struct KernelOverride: Codable, Equatable, Sendable {
		public var name: String
		public var path: String
		public var commandLine: String?
		public var overrideEnabled: Bool?

		public init(name: String, path: String, commandLine: String?, overrideEnabled: Bool?) {
			self.name = name
			self.path = path
			self.commandLine = commandLine
			self.overrideEnabled = overrideEnabled
		}
	}

	// vm.disk.resize: grow an owned storage disk to sizeBytes (shrink refuses).
	public struct ResizeDisk: Codable, Equatable, Sendable {
		public var name: String
		public var diskID: String
		public var sizeBytes: UInt64

		public init(name: String, diskID: String, sizeBytes: UInt64) {
			self.name = name
			self.diskID = diskID
			self.sizeBytes = sizeBytes
		}
	}

	// vm.disk.rename: rename an owned storage disk (its backing file moves; the disk id is
	// name-derived, so it changes).
	public struct RenameDisk: Codable, Equatable, Sendable {
		public var name: String
		public var diskID: String
		public var newName: String

		public init(name: String, diskID: String, newName: String) {
			self.name = name
			self.diskID = diskID
			self.newName = newName
		}
	}

	// vm.mount.setTag: change a mount's guest tag (next-boot effect, like other mount edits).
	public struct SetMountTag: Codable, Equatable, Sendable {
		public var name: String
		public var mountID: String
		public var tag: String

		public init(name: String, mountID: String, tag: String) {
			self.name = name
			self.mountID = mountID
			self.tag = tag
		}
	}

	// vm.mount.setKind (1.0.7): change how a mount reaches the guest (a MountKind value).
	public struct SetMountKind: Codable, Equatable, Sendable {
		public var name: String
		public var mountID: String
		public var kind: String

		public init(name: String, mountID: String, kind: String) {
			self.name = name
			self.mountID = mountID
			self.kind = kind
		}
	}

	// vm.kernel.rename: re-tag an owned kernel/initramfs file (its path and override key
	// migrate with it).
	public struct RenameKernel: Codable, Equatable, Sendable {
		public var name: String
		public var path: String
		public var tag: String

		public init(name: String, path: String, tag: String) {
			self.name = name
			self.path = path
			self.tag = tag
		}
	}

	// vm.ssh.set: nil fields leave that half unchanged (the setKernelOverride pattern).
	// alias (1.0.6) is the one field with a third state: "" resets it to the default.
	public struct SSHSet: Codable, Equatable, Sendable {
		public var name: String
		public var integrationEnabled: Bool?
		public var reverseApproved: Bool?
		public var alias: String?

		public init(
			name: String, integrationEnabled: Bool?, reverseApproved: Bool?,
			alias: String? = nil
		) {
			self.name = name
			self.integrationEnabled = integrationEnabled
			self.reverseApproved = reverseApproved
			self.alias = alias
		}
	}

	// op.cancel: cancel a running operation by id.
	public struct CancelOperation: Codable, Equatable, Sendable {
		public var id: String

		public init(id: String) {
			self.id = id
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
