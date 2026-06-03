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
			throw VirtualMachineError.critical("macOS platform not supported yet")
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
			throw VirtualMachineError.critical("macOS boot not supported yet")
		}
	}

	// Generic (virtio / USB) graphics + input for EFI/Linux. The macOS guest overrides these with
	// Mac graphics / keyboard / trackpad — added when macOS boot lands.
	func graphicsDevices() -> [VZGraphicsDeviceConfiguration] {
		[VMConfig.graphicsDeviceConfig()]
	}

	func keyboards() -> [VZKeyboardConfiguration] {
		[VZUSBKeyboardConfiguration()]
	}

	func pointingDevices() -> [VZPointingDeviceConfiguration] {
		[VZUSBScreenCoordinatePointingDeviceConfiguration()]
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
