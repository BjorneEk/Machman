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

extension VMConfig {

	// MARK: - Boot-mode-aware builders

	func makePlatform() throws -> VZPlatformConfiguration {
		switch boot {
		case .efi, .linuxKernel:
			let platform = VZGenericPlatformConfiguration()
			platform.machineIdentifier = getVmIdentifier()
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
			loader.variableStore = getEFIVariableStore()
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

	// Assembles the full VZ configuration. Shared by the normal boot path (VirtualMachine) and the
	// macOS installer so the device list lives in exactly one place.
	func makeVZVirtualMachineConfiguration() throws -> VZVirtualMachineConfiguration {
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
		vmConfig.directorySharingDevices = [directoryShareDeviceConfig(mainTag: "host-share")]
		try vmConfig.validate()
		return vmConfig
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
