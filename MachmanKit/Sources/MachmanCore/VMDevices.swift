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

// A built VZ configuration plus the serial pipe wiring its ports need bridged.
struct BuiltVM {
	let configuration: VZVirtualMachineConfiguration
	let serialWiring: [SerialWiring]
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

	// Generic (virtio / USB) graphics + input for EFI/Linux; Mac graphics / keyboard / trackpad
	// for a macOS guest. The Mac trackpad is only recognized by macOS 13+ guests, so a USB pointer
	// rides alongside it as a fallback (per Apple guidance).
	func graphicsDevices() -> [VZGraphicsDeviceConfiguration] {
		switch boot {
		case .efi, .linuxKernel:
			return [VMConfig.graphicsDeviceConfig()]
		case .macOS:
			let graphics = VZMacGraphicsDeviceConfiguration()
			let size = VMConfig.mainScreenSize(2560, 1440)
			graphics.displays = [VZMacGraphicsDisplayConfiguration(
				widthInPixels: size.width, heightInPixels: size.height, pixelsPerInch: 80)]
			return [graphics]
		}
	}

	func keyboards() -> [VZKeyboardConfiguration] {
		switch boot {
		case .efi, .linuxKernel:
			return [VZUSBKeyboardConfiguration()]
		case .macOS:
			return [VZMacKeyboardConfiguration()]
		}
	}

	func pointingDevices() -> [VZPointingDeviceConfiguration] {
		switch boot {
		case .efi, .linuxKernel:
			return [VZUSBScreenCoordinatePointingDeviceConfiguration()]
		case .macOS:
			return [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
		}
	}

	func consoleDevices() -> [VZConsoleDeviceConfiguration] {
		switch boot {
		case .efi, .linuxKernel:
			return [VMConfig.spiceAgentConsoleDeviceConfig()]
		case .macOS:
			return []
		}
	}

	// Build the configured serial ports over fresh pipe pairs, returning the host-end wiring for
	// the bridges. Console (virtio) ports come first so a Linux guest numbers them hvc0.. and the
	// PL011 uart ports ttyAMA0.. by their own order. Each pipe MUST be drained by a bridge or the
	// guest stalls writing to it.
	func serialPorts() -> (ports: [VZSerialPortConfiguration], wiring: [SerialWiring]) {
		var ports: [VZSerialPortConfiguration] = []
		var wiring: [SerialWiring] = []
		for index in consolePorts.indices {
			let (attachment, wire) = makeSerialPipe(kind: .console, index: index)
			let port = VZVirtioConsoleDeviceSerialPortConfiguration()
			port.attachment = attachment
			ports.append(port)
			wiring.append(wire)
		}
		for index in uartPorts.indices {
			guard let port = makePL011SerialPort() else {
				let why = VMConfig.privateSerialRejected()
					? "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) rejects "
						+ "the private PL011 device at VM start"
					: "the private PL011 class is unavailable"
				MachmanLogger.log(.passiveWarning, "skipping uart\(index) on \(name): \(why)")
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

	// macOS 26.6.1's security update removed the backend for the private serial devices: the
	// _VZPL011SerialPortConfiguration and _VZ16550SerialPortConfiguration classes still exist and
	// still validate, but the com.apple.Virtualization.VirtualMachine helper traps
	// (EXC_BREAKPOINT) decoding either of them, so EVERY start of a VM carrying one fails with an
	// opaque VZErrorInternal. Measured 2026-08-13 on 26.6.1 (25G76) with a minimal reproducer
	// (docs/local/socket-research/05-uart-availability.swift); 26.6.0 worked. Treat the private
	// serial devices as gone from that build on — a VM must start even if its uarts cannot.
	static func privateSerialRejected(
		by v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
	) -> Bool {
		(v.majorVersion, v.minorVersion, v.patchVersion) >= (26, 6, 1)
	}

	// Assembles the full VZ configuration. Shared by the normal boot path (VirtualMachine) and the
	// macOS installer so the device list lives in exactly one place. attachSerial is false for the
	// installer: it does not run bridges, and an undrained serial pipe would stall the guest.
	func makeVZVirtualMachineConfiguration(attachSerial: Bool = true) throws -> BuiltVM {
		let vmConfig = VZVirtualMachineConfiguration()
		vmConfig.cpuCount = getCPUCounte()
		vmConfig.memorySize = getMemorySize()
		vmConfig.platform = try makePlatform()
		vmConfig.bootLoader = try makeBootLoader()
		vmConfig.storageDevices = try diskArray()
		vmConfig.networkDevices = [networkDeviceConfig()]
		vmConfig.graphicsDevices = graphicsDevices()
		vmConfig.audioDevices = [VMConfig.inputAudioDeviceConfig(), VMConfig.outputAudioDeviceConfig()]
		vmConfig.keyboards = keyboards()
		vmConfig.pointingDevices = pointingDevices()
		vmConfig.consoleDevices = consoleDevices()
		var wiring: [SerialWiring] = []
		if attachSerial {
			let serial = serialPorts()
			vmConfig.serialPorts = serial.ports
			wiring = serial.wiring
		}
		vmConfig.directorySharingDevices = [directoryShareDeviceConfig(mainTag: "host-share")]
		try vmConfig.validate()
		return BuiltVM(configuration: vmConfig, serialWiring: wiring)
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

	static func graphicsDeviceConfig() -> VZVirtioGraphicsDeviceConfiguration {
		let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
		let size = mainScreenSize(2560, 1440)
		graphicsDevice.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: size.width, heightInPixels: size.height)]
		return graphicsDevice
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

	static func spiceAgentConsoleDeviceConfig() -> VZVirtioConsoleDeviceConfiguration {
		let consoleDevice = VZVirtioConsoleDeviceConfiguration()

		let spiceAgentPort = VZVirtioConsolePortConfiguration()
		spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
		spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
		consoleDevice.ports[0] = spiceAgentPort

		return consoleDevice
	}
}
