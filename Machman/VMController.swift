//
//  VMController.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-27.
//

import Foundation
import Virtualization

class VMController: NSObject, ObservableObject, VZVirtualMachineDelegate {
	var virtualMachine: VZVirtualMachine?
	var isoPath: String?
	var diskPath: String
	var efiVarsPath: String
	var vmIdentifierPath: String
	
	init(vmPath: String, cpuCount: Int = 4, ramSize: UInt64 = (2 << 31), iso: String? = nil) {
		self.isoPath = iso
		self.diskPath = vmPath + "/disk.raw"
		self.efiVarsPath = vmPath + "/efi_vars.fd"
		self.vmIdentifierPath = vmPath + "/vm_identifier"

		super.init()

		do {
			let config = try createVMConfiguration(
				diskPath: diskPath,
				cpuCount: cpuCount,
				ramSize: ramSize,
				isoPath: isoPath
			)
			virtualMachine = VZVirtualMachine(configuration: config)
			virtualMachine?.delegate = self
		} catch {
			fatalError("Configuration error: \(error)")
		}
	}
	private func computeCPUCount() -> Int {
		let totalAvailableCPUs = ProcessInfo.processInfo.processorCount

		var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
		virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
		virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

		return virtualCPUCount
	}

	private func computeMemorySize(memorySize: UInt64) -> UInt64 {
		var realMemorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
		realMemorySize = min(realMemorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
		return realMemorySize
	}

	private func createAndSaveVmIdentifier() -> VZGenericMachineIdentifier {
		let machineIdentifier = VZGenericMachineIdentifier()

		// Store the machine identifier to disk so you can retrieve it for subsequent boots.
		try! machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: vmIdentifierPath))
		return machineIdentifier
	}
	
	private func retrieveVmIdentifier() -> VZGenericMachineIdentifier {
		let fileURL = URL(fileURLWithPath: vmIdentifierPath)
	    
		if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
			if let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: data) {
				return machineIdentifier
			} else {
				fatalError("Failed to create the machine identifier from data.")
			}
		} else {
			// Either the file doesn't exist or it's empty; create and save a new one.
			return createAndSaveVmIdentifier()
		}
	}

	private func createEFIVariableStore() -> VZEFIVariableStore {
		guard let efiVariableStore = try? VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVarsPath)) else {
			fatalError("Failed to create the EFI variable store.")
		}
		return efiVariableStore
	}

	private func retrieveEFIVariableStore() -> VZEFIVariableStore {
		if !FileManager.default.fileExists(atPath: efiVarsPath) {
			//return createEFIVariableStore()
			fatalError("No EFI store.")
		}

		return VZEFIVariableStore(url: URL(fileURLWithPath: efiVarsPath))
	}
	private func createUSBMassStorageDeviceConfiguration(isoPath: String) -> VZUSBMassStorageDeviceConfiguration {
		guard let intallerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath:isoPath), readOnly: true) else {
			fatalError("Failed to create installer's disk attachment.")
		}

		return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
	}

	private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
		let networkDevice = VZVirtioNetworkDeviceConfiguration()
		networkDevice.attachment = VZNATNetworkDeviceAttachment()

		return networkDevice
	}

	private func createGraphicsDeviceConfiguration() -> VZVirtioGraphicsDeviceConfiguration {
		let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
		var width = 2560
		var height = 1440
		if let mainScreen = NSScreen.main {
			width = Int(mainScreen.frame.width)
			height = Int(mainScreen.frame.height)
		}
		graphicsDevice.scanouts = [
			VZVirtioGraphicsScanoutConfiguration(widthInPixels: width, heightInPixels: height)
		]

		return graphicsDevice
	}

	private func createInputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
		let inputAudioDevice = VZVirtioSoundDeviceConfiguration()

		let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
		inputStream.source = VZHostAudioInputStreamSource()

		inputAudioDevice.streams = [inputStream]
		return inputAudioDevice
	}

	private func createOutputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
		let outputAudioDevice = VZVirtioSoundDeviceConfiguration()

		let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
		outputStream.sink = VZHostAudioOutputStreamSink()

		outputAudioDevice.streams = [outputStream]
		return outputAudioDevice
	}

	private func createMainDiskImage(diskPath: String, size: UInt64 = 32 * 1024 * 1024 * 1024) {
		let diskCreated = FileManager.default.createFile(atPath: diskPath, contents: nil, attributes: nil)
		if !diskCreated {
			fatalError("Failed to create the main disk image.")
		}

		guard let mainDiskFileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: diskPath)) else {
			fatalError("Failed to get the file handle for the main disk image.")
		}

		do {
		// 64 GB disk space.
			try mainDiskFileHandle.truncate(atOffset: size)
		} catch {
			fatalError("Failed to truncate the main disk image.")
		}
	}

	private func createSpiceAgentConsoleDeviceConfiguration() -> VZVirtioConsoleDeviceConfiguration {
		let consoleDevice = VZVirtioConsoleDeviceConfiguration()

		let spiceAgentPort = VZVirtioConsolePortConfiguration()
		spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
		spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
		consoleDevice.ports[0] = spiceAgentPort

		return consoleDevice
	}

	private func createBlockDeviceConfiguration(diskPath: String) -> VZVirtioBlockDeviceConfiguration {
		if !FileManager.default.fileExists(atPath: diskPath) {
			createMainDiskImage(diskPath: diskPath)
		}
		guard let mainDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: diskPath), readOnly: false) else {
			fatalError("Failed to create main disk attachment.")
		}

		let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
		return mainDisk
	}

	private func createVMConfiguration(diskPath: String, cpuCount: Int = 4, ramSize: UInt64 = 2 << 31, isoPath: String? = nil) throws -> VZVirtualMachineConfiguration {
		let config = VZVirtualMachineConfiguration()
		
		// Set CPU and memory.
		config.cpuCount = min(computeCPUCount(), cpuCount)
		config.memorySize = computeMemorySize(memorySize: ramSize)
	
		let platform = VZGenericPlatformConfiguration()
		let bootloader = VZEFIBootLoader()
		let disksArray = NSMutableArray()
		
		if let isoPath = isoPath {
			platform.machineIdentifier = createAndSaveVmIdentifier()
			bootloader.variableStore = createEFIVariableStore()
			disksArray.add(createUSBMassStorageDeviceConfiguration(isoPath: isoPath))
		} else {
			platform.machineIdentifier = retrieveVmIdentifier()
			bootloader.variableStore = retrieveEFIVariableStore()
		}

		config.platform = platform
		config.bootLoader = bootloader
		
		disksArray.add(createBlockDeviceConfiguration(diskPath: diskPath))
		guard let disks = disksArray as? [VZStorageDeviceConfiguration] else {
		    fatalError("Invalid disksArray.")
		}
		config.storageDevices = disks
		
		config.networkDevices = [createNetworkDeviceConfiguration()]
		config.graphicsDevices = [createGraphicsDeviceConfiguration()]
		config.audioDevices = [createInputAudioDeviceConfiguration(), createOutputAudioDeviceConfiguration()]

		config.keyboards = [VZUSBKeyboardConfiguration()]
		config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
		config.consoleDevices = [createSpiceAgentConsoleDeviceConfiguration()]
		
		do {
			try config.validate()
		} catch {
			fatalError("Failed to validate configuration: \(error)")
		}
		return config
	}

	public func startVM() {
		guard let vm = virtualMachine else {
			fatalError("No VM configured.")
		}

		vm.start { result in
			DispatchQueue.main.async {
				switch result {
				case .failure(let error):
					fatalError("Failed to start VM: \(error)")
				case .success:
					break;
				}
			}
		}
	}

	func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
		DispatchQueue.main.async {
			fatalError("VM stopped with error: \(error)")
		}
	}
	
	func guestDidStop(_ virtualMachine: VZVirtualMachine) {
		DispatchQueue.main.async {
			NSApplication.shared.keyWindow?.close()
			//NSApplication.shared.terminate(nil)
		}
	}
}
