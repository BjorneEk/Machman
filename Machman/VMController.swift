//
//  VMController.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-27.
//

import Foundation
import Virtualization
import SwiftUI

class VMController: NSObject, ObservableObject, VZVirtualMachineDelegate {
	var virtualMachine: VZVirtualMachine?
	var isoPath: String?
	var vmConfig: VMConfig
	var viewModel: VMListViewModel?

	init(_ vmConfig: VMConfig, iso: String? = nil) {
		self.isoPath = iso
		self.vmConfig = vmConfig
		super.init()

		do {
			let config = try createVMConfiguration(
				vmConfig: vmConfig,
				isoPath: isoPath
			)
			virtualMachine = VZVirtualMachine(configuration: config)
			virtualMachine?.delegate = self
		} catch {
			fatalError("Configuration error: \(error)")
		}
	}

	private func createUSBMassStorageDeviceConfiguration(isoPath: String) -> VZUSBMassStorageDeviceConfiguration {
		guard let intallerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath:isoPath), readOnly: true) else {
			fatalError("Failed to create installer's disk attachment.")
		}
		return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
	}

	private func createBridgeNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
		guard let interface = VZBridgedNetworkInterface.networkInterfaces.first else {
			print("No bridged network interfaces available")
			return createNetworkDeviceConfiguration()
		}

		let networkDevice = VZVirtioNetworkDeviceConfiguration()
		networkDevice.attachment = VZBridgedNetworkDeviceAttachment(interface: interface)
		return networkDevice
	}

	private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
		
		let networkDevice = VZVirtioNetworkDeviceConfiguration()
		let natAttachment = VZNATNetworkDeviceAttachment()

		networkDevice.attachment = natAttachment

		return networkDevice
	}

	func mainScreenSize(defaultWidth: Int, defaultHeight: Int) -> (width: Int, height: Int) {
		var width = defaultWidth
		var height = defaultHeight
		if let mainScreen = NSScreen.main {
			width = Int(mainScreen.frame.width)
			height = Int(mainScreen.frame.height)
		}
		return (width: width, height: height)
	}
	private func createGraphicsDeviceConfiguration() -> VZVirtioGraphicsDeviceConfiguration {
		let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
		let size = mainScreenSize(
			defaultWidth: 2560,
			defaultHeight: 1440)
		graphicsDevice.scanouts = [
			VZVirtioGraphicsScanoutConfiguration(widthInPixels: size.width, heightInPixels: size.height)
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

	private func createSpiceAgentConsoleDeviceConfiguration() -> VZVirtioConsoleDeviceConfiguration {
		let consoleDevice = VZVirtioConsoleDeviceConfiguration()

		let spiceAgentPort = VZVirtioConsolePortConfiguration()
		spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
		spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
		consoleDevice.ports[0] = spiceAgentPort

		return consoleDevice
	}

	private func createBlockDeviceConfiguration(diskPath: String) -> VZVirtioBlockDeviceConfiguration {
		guard let mainDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: diskPath), readOnly: false) else {
			fatalError("Failed to create main disk attachment for: \(vmConfig.name)")
		}

		let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
		return mainDisk
	}

	func createDirectoryShareDeviceConfiguration() -> VZVirtioFileSystemDeviceConfiguration {
		let directoriesToShare: [String: VZSharedDirectory] = Dictionary(
			uniqueKeysWithValues: vmConfig.mountPoints.map { mount in
				(mount.tag, VZSharedDirectory(url: URL(fileURLWithPath: mount.path), readOnly: false))
			}
		)
		let multipleDirectoryShare = VZMultipleDirectoryShare(directories: directoriesToShare)
		// Create the VZVirtioFileSystemDeviceConfiguration and assign it a unique tag.
		let sharingConfiguration = VZVirtioFileSystemDeviceConfiguration(tag: "host-share")
		sharingConfiguration.share = multipleDirectoryShare


		return sharingConfiguration
	}

	private func createVMConfiguration(vmConfig: VMConfig, isoPath: String? = nil) throws -> VZVirtualMachineConfiguration {
		let config = VZVirtualMachineConfiguration()
		
		// Set CPU and memory.
		config.cpuCount = vmConfig.getCPUCounte()
		config.memorySize = vmConfig.getMemorySize()

		let platform = VZGenericPlatformConfiguration()
		let bootloader = VZEFIBootLoader()
		let disksArray = NSMutableArray()
		
		if let isoPath = isoPath {
			platform.machineIdentifier = vmConfig.getVmIdentifier()
			bootloader.variableStore = vmConfig.getEFIVariableStore()
			disksArray.add(createUSBMassStorageDeviceConfiguration(isoPath: isoPath))
		} else {
			platform.machineIdentifier = vmConfig.getVmIdentifier()
			bootloader.variableStore = vmConfig.getEFIVariableStore()
		}

		config.platform = platform
		config.bootLoader = bootloader
		
		disksArray.add(createBlockDeviceConfiguration(diskPath: vmConfig.diskImagePath()))
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
		config.directorySharingDevices = [createDirectoryShareDeviceConfiguration()]

		do {
			try config.validate()
		} catch {
			fatalError("Failed to validate configuration for: \(vmConfig.name): \(error)")
		}
		return config
	}

	public func startVM() {
		guard let vm = virtualMachine else {
			fatalError("No VM configured for: \(vmConfig.name)")
		}

		vm.start { result in
			DispatchQueue.main.async {
				switch result {
				case .failure(let error):
					fatalError("Failed to start \(self.vmConfig.name): \(error)")
				case .success:
					try? self.vmConfig.start()
					print("started \(self.vmConfig.name), \(self.vmConfig.cpuCount) \(self.vmConfig.memorySize)\n")
					break;
				}
			}
		}
	}
	public func startVMWindow(viewModel: VMListViewModel) {
		guard let vm = virtualMachine else {
			fatalError("No VM configured for: \(vmConfig.name)")
		}

		self.viewModel = viewModel
		let size = mainScreenSize(
			defaultWidth: 2560,
			defaultHeight: 1440)

		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)

		// Create a VMView with the new controller.
		let vmView = VMView(vmController: self)
		// Create a new NSWindow and host the VMView.

		window.center()
		window.title = vmConfig.name
		window.contentView = NSHostingView(rootView: vmView)
		window.makeKeyAndOrderFront(nil)
		window.isReleasedWhenClosed = false

		NotificationCenter.default.addObserver(self,
			selector: #selector(windowDidClose(notification:)),
			name: NSWindow.willCloseNotification,
			object: window)

		vm.start { result in
			DispatchQueue.main.async {
				switch result {
				case .failure(let error):
					fatalError("Failed to start \(self.vmConfig.name): \(error)")
				case .success:
					try? self.vmConfig.start(window: window)
					self.viewModel?.forceUpdate()
					break;
				}
			}
		}
	}
	func stopVM() {
		guard let vm = virtualMachine else {
			print("No VM is running.")
			return
		}

		vm.stop { error in
			DispatchQueue.main.async {
				if let error = error {
					print("Failed to stop VM: \(self.vmConfig.name): \(error)")
				} else {
					print("VM: \(self.vmConfig.name) stopped successfully.")
				}
			}
		}

		try? self.vmConfig.stop()
		self.vmConfig.window = nil
		viewModel?.forceUpdate()
	}

	func vmState() -> VMState {
		return vmConfig.state
	}

	@objc func windowDidClose(notification: Notification) {
		DispatchQueue.main.async {
			if self.vmConfig.state != .stopped {
				print("stopped window")
				self.stopVM()
			}
		}
	}

	func guestDidStop(_ virtualMachine: VZVirtualMachine) {
		DispatchQueue.main.async {
			if self.vmConfig.state != .stopped {
				try? self.vmConfig.stop()
				self.viewModel?.forceUpdate()
				print("stopped!")
			}
		}
	}

	func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
		DispatchQueue.main.async {
			if self.vmConfig.state != .stopped {
				try? self.vmConfig.stop()
				self.viewModel?.forceUpdate()
				print("stopped woth error \(error)")
			}
		}
	}
}
