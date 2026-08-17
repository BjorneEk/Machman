//
//  VMDevices.swift
//  Machman
//
//  VZ device construction for VMConfig, split out from the model. The boot-mode-aware builders
//  (makePlatform / makeBootLoader / graphicsDevices / keyboards / pointingDevices) are the seam
//  where a new boot mode plugs in: add a BootConfig case, then one arm in each switch here.
//

import Foundation
import Virtualization
import AppKit
import MachmanAPI

// The host ends of one serial port's pipes, handed to a SerialPortBridge. The VZ attachment holds
// the other ends. The bridge writes guest input to `toGuest` and reads guest output from
// `fromGuest`.
struct SerialWiring {
	let kind: SerialPortKind
	let index: Int
	let toGuest: FileHandle
	let fromGuest: FileHandle
}

// A built VZ configuration plus the serial pipe wiring its ports need bridged, plus human
// warnings for configured devices the builder had to skip (host gates, boot-mode misfits).
struct BuiltVM {
	let configuration: VZVirtualMachineConfiguration
	let serialWiring: [SerialWiring]
	let warnings: [String]
}

extension VMConfig {

	// MARK: - Boot-mode-aware builders

	func makePlatform() throws -> VZPlatformConfiguration {
		switch boot {
		case .efi, .linuxKernel:
			let platform = VZGenericPlatformConfiguration()
			platform.machineIdentifier = try getVmIdentifier()
			return platform
		case .macOS:
			let platform = VZMacPlatformConfiguration()
			platform.hardwareModel = try getMacHardwareModel()
			platform.machineIdentifier = try getMacMachineIdentifier()
			platform.auxiliaryStorage = try getMacAuxiliaryStorage()
			return platform
		}
	}

	func makeBootLoader() throws -> VZBootLoader {
		switch boot {
		case .efi:
			let loader = VZEFIBootLoader()
			loader.variableStore = try getEFIVariableStore()
			return loader
		case .linuxKernel(let k):
			guard FileManager.default.fileExists(atPath: k.kernelPath) else {
				throw VirtualMachineError.critical("Kernel image not found: '\(k.kernelPath)'")
			}
			let loader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: k.kernelPath))
			if let initrd = k.initialRamdiskPath {
				loader.initialRamdiskURL = URL(fileURLWithPath: initrd)
			}
			loader.commandLine = k.commandLine
			return loader
		case .macOS:
			return VZMacOSBootLoader()
		}
	}

	// MARK: - Config-driven device resolution (1.0.4)

	// The devices that actually attach at this start: the configured list minus disabled
	// entries (silently honored — that's what disabling means) minus entries this host or
	// boot mode cannot carry (warned, so the user learns the VM started with fewer devices).
	func resolvedDevices() -> (attach: [DeviceKind: GuestDevice], warnings: [String]) {
		var attach: [DeviceKind: GuestDevice] = [:]
		var warnings: [String] = []
		let macGuest: Bool = { if case .macOS = boot { return true }; return false }()
		for device in devices {
			guard device.enabled else { continue }
			switch device.deviceKind {
			case .unknown:
				warnings.append(
					"skipping unknown device '\(device.kind)' on \(name) "
						+ "(written by a newer Machman)")
			case .trackpad where !macGuest:
				warnings.append("skipping trackpad on \(name): it needs a macOS guest")
			case .consoleLoginInstaller where !macGuest:
				warnings.append(
					"skipping the console login installer on \(name): it needs a macOS guest")
			case .clipboard where macGuest:
				warnings.append(
					"skipping clipboard sharing on \(name): not supported for macOS guests")
			case .rosetta where macGuest:
				warnings.append("skipping rosetta on \(name): not supported for macOS guests")
			case .rosetta where VZLinuxRosettaDirectoryShare.availability != .installed:
				warnings.append(
					"skipping rosetta on \(name): Rosetta is not installed on this host")
			case let kind:
				attach[kind] = device
			}
		}
		return (attach, warnings)
	}

	// Generic (virtio / USB) graphics for EFI/Linux; Mac graphics for a macOS guest.
	// Resolution comes from the device's settings, falling back to the host screen size
	// (and 80 ppi for Mac guests) — exactly the pre-1.0.4 hard-coded behavior.
	func graphicsDevices(for device: GuestDevice?) -> [VZGraphicsDeviceConfiguration] {
		guard let device else { return [] }
		let fallback = VMConfig.mainScreenSize(2560, 1440)
		let width = device.displayWidthPixels ?? fallback.width
		let height = device.displayHeightPixels ?? fallback.height
		switch boot {
		case .efi, .linuxKernel:
			let graphics = VZVirtioGraphicsDeviceConfiguration()
			graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
				widthInPixels: width, heightInPixels: height)]
			return [graphics]
		case .macOS:
			let graphics = VZMacGraphicsDeviceConfiguration()
			graphics.displays = [VZMacGraphicsDisplayConfiguration(
				widthInPixels: width, heightInPixels: height,
				pixelsPerInch: device.displayPixelsPerInch ?? 80)]
			return [graphics]
		}
	}

	// The Mac keyboard/trackpad classes need a macOS guest; EFI/Linux get USB variants.
	// The kind resolves to the boot-appropriate class here, so device lists survive
	// boot-mode changes unedited.
	func keyboards(present: Bool) -> [VZKeyboardConfiguration] {
		guard present else { return [] }
		switch boot {
		case .efi, .linuxKernel:
			return [VZUSBKeyboardConfiguration()]
		case .macOS:
			return [VZMacKeyboardConfiguration()]
		}
	}

	// trackpad and pointer are separate devices since 1.0.4 (the engine used to always pair
	// them for mac guests — the implied set still does; users can now drop either).
	func pointingDevices(trackpad: Bool, pointer: Bool) -> [VZPointingDeviceConfiguration] {
		var out: [VZPointingDeviceConfiguration] = []
		if trackpad { out.append(VZMacTrackpadConfiguration()) }
		if pointer { out.append(VZUSBScreenCoordinatePointingDeviceConfiguration()) }
		return out
	}

	func consoleDevices(clipboard device: GuestDevice?) -> [VZConsoleDeviceConfiguration] {
		guard let device else { return [] }
		return [VMConfig.spiceAgentConsoleDeviceConfig(
			sharesClipboard: device.sharesClipboard ?? true)]
	}

	// Rosetta rides as an EXTRA directory-sharing device with the well-known "rosetta" tag,
	// separate from the "host-share" multi-share. Availability is pre-checked in
	// resolvedDevices(); a throw here still degrades to a warning at the call site.
	func rosettaShareDeviceConfig() throws -> VZVirtioFileSystemDeviceConfiguration {
		let share = try VZLinuxRosettaDirectoryShare()
		let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
		device.share = share
		return device
	}

	// Build the configured serial ports over fresh pipe pairs, returning the host-end wiring for
	// the bridges. Console (virtio) ports come first so a Linux guest numbers them hvc0.. and the
	// PL011 uart ports ttyAMA0.. by their own order. Each pipe MUST be drained by a bridge or the
	// guest stalls writing to it.
	func serialPorts() -> (ports: [VZSerialPortConfiguration], wiring: [SerialWiring]) {
		var ports: [VZSerialPortConfiguration] = []
		var wiring: [SerialWiring] = []
		// Disabled ports (1.0.4) are skipped like removed ones — the guest numbers the rest
		// compactly; wiring keeps the CONFIG index so sockets/logs stay stably keyed.
		for index in consolePorts.indices where consolePorts[index].enabled {
			let (attachment, wire) = makeSerialPipe(kind: .console, index: index)
			let port = VZVirtioConsoleDeviceSerialPortConfiguration()
			port.attachment = attachment
			ports.append(port)
			wiring.append(wire)
		}
		let enabledUarts = uartPorts.indices.filter { uartPorts[$0].enabled }
		let uartIssue = enabledUarts.isEmpty ? nil : VMConfig.uartUnavailability()
		for index in enabledUarts {
			guard let port = makePL011SerialPort() else {
				MachmanLogger.log(.passiveWarning, "skipping uart\(index) on \(name): "
					+ (uartIssue?.message ?? "the private PL011 class is unavailable"))
				continue
			}
			let (attachment, wire) = makeSerialPipe(kind: .uart, index: index)
			port.attachment = attachment
			ports.append(port)
			wiring.append(wire)
		}
		return (ports, wiring)
	}

	private func makeSerialPipe(
		kind: SerialPortKind, index: Int
	) -> (VZFileHandleSerialPortAttachment, SerialWiring) {
		let toGuest = Pipe()
		let fromGuest = Pipe()
		let attachment = VZFileHandleSerialPortAttachment(
			fileHandleForReading: toGuest.fileHandleForReading,
			fileHandleForWriting: fromGuest.fileHandleForWriting)
		let wire = SerialWiring(
			kind: kind, index: index,
			toGuest: toGuest.fileHandleForWriting, fromGuest: fromGuest.fileHandleForReading)
		return (attachment, wire)
	}

	// The private PL011 UART class (a real /dev/ttyAMA* in the guest, drivable by bare-metal
	// kernels). Present in every SDK since macOS 11 and usable with only the public virtualization
	// entitlement, but private — guard it and skip cleanly if it ever disappears.
	private func makePL011SerialPort() -> VZSerialPortConfiguration? {
		guard !VMConfig.privateSerialRejected() else { return nil }
		guard let cls = NSClassFromString("_VZPL011SerialPortConfiguration") as? NSObject.Type,
			let port = cls.perform(NSSelectorFromString("new"))?.takeRetainedValue()
				as? VZSerialPortConfiguration else {
			return nil
		}
		return port
	}

	// macOS 26.6.1's security update reclassified the private serial devices (PL011 AND 16550) as
	// "restricted devices" gated behind the com.apple.private.virtualization entitlement: the
	// classes still exist and validate, but the com.apple.Virtualization.VirtualMachine helper
	// traps ("Restricted devices require the com.apple.private.virtualization entitlement.") for an
	// unentitled caller, so EVERY start of a VM carrying one fails with an opaque VZErrorInternal.
	// That entitlement is com.apple.private.* — honoured only for Apple-signed binaries or with SIP
	// disabled + amfi_get_out_of_my_way=1; carrying it on a SIP-on machine SIGKILLs EVERY VZ start
	// (measured), so we must never add it by default. Machman stays unentitled, so on ≥ 26.6.1 a
	// VM must start even if its uarts cannot. Measured 2026-08-13 on 26.6.1 (25G76); 26.6.0 worked.
	// Reproducer: docs/local/socket-research/05-uart-availability.swift.
	static func privateSerialRejected(
		by v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
	) -> Bool {
		let g = SerialPortSupport.privateUARTGatedSince
		return (v.majorVersion, v.minorVersion, v.patchVersion)
			>= (g.majorVersion, g.minorVersion, g.patchVersion)
	}

	// The reason a uart (private PL011) port cannot be attached on this host, or nil if uarts work
	// here. The single source for the VZ-builder skip log, the start-time warning event, and the
	// wire's SerialPortInfo.unavailable — so a client that queries a VM learns exactly why a
	// configured uart is inert. Checks the macOS version gate first, then the class's presence.
	static func uartUnavailability() -> SerialPortUnavailability? {
		if privateSerialRejected() {
			let v = ProcessInfo.processInfo.operatingSystemVersion
			let host = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
			return SerialPortUnavailability(
				reason: .privateUARTGated,
				message: "UART unavailable: macOS \(host) gates the private PL011 device "
					+ "(com.apple.private.virtualization required, since macOS "
					+ "\(SerialPortSupport.privateUARTGatedSinceDisplay)); configured uart ports "
					+ "are left unattached.",
				sinceOSVersion: SerialPortSupport.privateUARTGatedSinceDisplay)
		}
		if NSClassFromString("_VZPL011SerialPortConfiguration") == nil {
			return SerialPortUnavailability(
				reason: .classUnavailable,
				message: "UART unavailable: the private PL011 device class is not present in this "
					+ "macOS build; configured uart ports are left unattached.")
		}
		return nil
	}

	// Assembles the full VZ configuration from the persisted device list (1.0.4). Shared by
	// the normal boot path (VirtualMachine) and the macOS installer so the device list lives
	// in exactly one place. attachSerial is false for the installer: it does not run bridges,
	// and an undrained serial pipe would stall the guest.
	func makeVZVirtualMachineConfiguration(attachSerial: Bool = true) throws -> BuiltVM {
		let resolved = resolvedDevices()
		let byKind = resolved.attach
		var warnings = resolved.warnings
		let vmConfig = VZVirtualMachineConfiguration()
		vmConfig.cpuCount = getCPUCounte()
		vmConfig.memorySize = getMemorySize()
		vmConfig.platform = try makePlatform()
		vmConfig.bootLoader = try makeBootLoader()
		vmConfig.storageDevices = try diskArray()
		vmConfig.networkDevices = byKind[.network] != nil ? [networkDeviceConfig()] : []
		vmConfig.graphicsDevices = graphicsDevices(for: byKind[.graphics])
		var audio: [VZAudioDeviceConfiguration] = []
		if byKind[.audioInput] != nil { audio.append(VMConfig.inputAudioDeviceConfig()) }
		if byKind[.audioOutput] != nil { audio.append(VMConfig.outputAudioDeviceConfig()) }
		vmConfig.audioDevices = audio
		vmConfig.keyboards = keyboards(present: byKind[.keyboard] != nil)
		vmConfig.pointingDevices = pointingDevices(
			trackpad: byKind[.trackpad] != nil, pointer: byKind[.pointer] != nil)
		vmConfig.consoleDevices = consoleDevices(clipboard: byKind[.clipboard])
		if byKind[.entropy] != nil {
			vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
		}
		var wiring: [SerialWiring] = []
		if attachSerial {
			let serial = serialPorts()
			vmConfig.serialPorts = serial.ports
			wiring = serial.wiring
		}
		// macOS guests automount the share at /Volumes/My Shared Files (one subdirectory
		// per mount tag); other guests keep mounting the "host-share" tag by hand.
		let macGuest: Bool = { if case .macOS = boot { return true }; return false }()
		let shareTag = macGuest
			? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
			: GuestPaths.shareTag
		var extraShares: [String: VZSharedDirectory] = [:]
		if byKind[.guestSetup] != nil {
			// Any guest: read-only payload beside a writable report drop-box, both riding
			// the one share device (reserved names; readOnly is per-directory). A writable
			// script would let any guest process swap it before the admin sudo-runs it.
			do {
				let (payload, report) = try GuestSetupInstaller.writePayload(for: self)
				extraShares[GuestSetupInstaller.directoryName] =
					VZSharedDirectory(url: payload, readOnly: true)
				extraShares[GuestSetupInstaller.reportDirectoryName] =
					VZSharedDirectory(url: report, readOnly: false)
			} catch {
				warnings.append(
					"skipping the guest setup on \(name): \(error.localizedDescription)")
			}
		}
		var shares: [VZDirectorySharingDeviceConfiguration] =
			[directoryShareDeviceConfig(mainTag: shareTag, extraDirectories: extraShares)]
		if byKind[.rosetta] != nil {
			do {
				shares.append(try rosettaShareDeviceConfig())
			} catch {
				warnings.append("skipping rosetta on \(name): \(error.localizedDescription)")
			}
		}
		vmConfig.directorySharingDevices = shares
		if nestedVirtualization {
			if let generic = vmConfig.platform as? VZGenericPlatformConfiguration,
				VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
				generic.isNestedVirtualizationEnabled = true
			} else {
				warnings.append(
					"skipping nested virtualization on \(name): "
						+ "not supported for this host or boot mode")
			}
		}
		do {
			try vmConfig.validate()
		} catch {
			// User-editable devices make validate() the primary failure path — surface a
			// readable machmanCode'd message instead of leaking "Error Domain=VZErrorDomain…".
			let ns = error as NSError
			if ns.domain == VZError.errorDomain {
				throw MachmanError(
					code: .virtualizationFailure,
					message: "configuration invalid: \(ns.localizedDescription)")
			}
			throw error
		}
		return BuiltVM(configuration: vmConfig, serialWiring: wiring, warnings: warnings)
	}

	// MARK: - Device factories

	func networkDeviceConfig() -> VZVirtioNetworkDeviceConfiguration {
		let networkDevice = VZVirtioNetworkDeviceConfiguration()
		networkDevice.attachment = VZNATNetworkDeviceAttachment()
		networkDevice.macAddress = getOrCreateMACAddress()
		return networkDevice
	}

	static func mainScreenSize(_ defaultWidth: Int, _ defaultHeight: Int) -> (width: Int, height: Int) {
		var width = defaultWidth
		var height = defaultHeight
		if let mainScreen = NSScreen.main {
			width = Int(mainScreen.frame.width)
			height = Int(mainScreen.frame.height)
		}
		return (width: width, height: height)
	}

	static func inputAudioDeviceConfig() -> VZVirtioSoundDeviceConfiguration {
		let inputAudioDevice = VZVirtioSoundDeviceConfiguration()
		let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
		inputStream.source = VZHostAudioInputStreamSource()
		inputAudioDevice.streams = [inputStream]
		return inputAudioDevice
	}

	static func outputAudioDeviceConfig() -> VZVirtioSoundDeviceConfiguration {
		let outputAudioDevice = VZVirtioSoundDeviceConfiguration()
		let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
		outputStream.sink = VZHostAudioOutputStreamSink()
		outputAudioDevice.streams = [outputStream]
		return outputAudioDevice
	}

	static func spiceAgentConsoleDeviceConfig(
		sharesClipboard: Bool = true
	) -> VZVirtioConsoleDeviceConfiguration {
		let consoleDevice = VZVirtioConsoleDeviceConfiguration()

		let spiceAgentPort = VZVirtioConsolePortConfiguration()
		spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
		let attachment = VZSpiceAgentPortAttachment()
		// Explicit now (1.0.4): the framework default is true, but the setting is user-facing.
		attachment.sharesClipboard = sharesClipboard
		spiceAgentPort.attachment = attachment
		consoleDevice.ports[0] = spiceAgentPort

		return consoleDevice
	}
}
