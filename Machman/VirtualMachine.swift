//
//  ViritualMachine.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import Foundation
import Virtualization
import SwiftUI
import ScreenCaptureKit
import AVFoundation


enum VirtualMachineLog: Identifiable {
	case error(String)
	case warning(String)
	case message(String)
	var id: UUID {
		UUID()
	}
}

enum VirtualMachineError: Error {
	case critical(String)
}

class VirtualMachine: NSObject, ObservableObject, VZVirtualMachineDelegate, Identifiable  {
	let id = UUID()
	var virtualMachine: VZVirtualMachine? = nil
	@State var config: VMConfig
	@State var log: [VirtualMachineLog] = []
	@State var previewImage: NSImage?
	//var vmView: VZVirtualMachineView?
	var viewModel: VMListViewModel?

	init(config: VMConfig) {
		self.config = config
		super.init()
	}
	static func == (lhs: VirtualMachine, rhs: VirtualMachine) -> Bool {
		lhs.config.name == rhs.config.name
	}
	func log(_ e: VirtualMachineLog) {
		self.log.append(e)
	}

	func log(error: String) {
		print(error)
		self.log.append(.error(error))
	}

	func log(message: String) {
		print(message)
		self.log.append(.message(message))
	}

	func log(warning: String) {
		print(warning)
		self.log.append(.warning(warning))
	}

	func err(msg: String) -> VirtualMachineError {
		print(msg)
		log(error: msg)
		return .critical(msg)
	}
	func updatePreview(img: NSImage) {
		self.previewImage = img
	}
	private func configureVM(isoPath: URL? = nil) -> VZVirtualMachineConfiguration? {
		let vmConfig = VZVirtualMachineConfiguration()

		vmConfig.cpuCount = config.getCPUCounte()
		vmConfig.memorySize = config.getMemorySize()

		let platform = VZGenericPlatformConfiguration()
		let bootloader = VZEFIBootLoader()

		platform.machineIdentifier = config.getVmIdentifier()
		bootloader.variableStore = config.getEFIVariableStore()

		vmConfig.platform = platform
		vmConfig.bootLoader = bootloader

		do {
			vmConfig.storageDevices = try config.diskArray()
		} catch {
			log(error: "\(error)")
			return nil
		}

		vmConfig.networkDevices = [VMConfig.networkDeviceConfig()]
		vmConfig.graphicsDevices = [VMConfig.graphicsDeviceConfig()]
		vmConfig.audioDevices = [VMConfig.inputAudioDeviceConfig(), VMConfig.outputAudioDeviceConfig()]
		vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
		vmConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
		vmConfig.consoleDevices = [VMConfig.spiceAgentConsoleDeviceConfig()]
		vmConfig.directorySharingDevices = [config.directoryShareDeviceConfig(mainTag: "host-share")]

		do {
			try vmConfig.validate()
		} catch {
			log(error: "Failed to validate configuration for: \(config.name): \(error)")
			return nil
		}
		return vmConfig
	}

	public func startVMWindow(viewModel: VMListViewModel, isoPath: URL? = nil) throws {

		guard let vmConf = configureVM(isoPath: isoPath) else {
			throw err(msg: "Failed to create VM configuration")
		}

		self.viewModel = viewModel
		self.virtualMachine = VZVirtualMachine(configuration: vmConf)
		self.virtualMachine?.delegate = self

		guard let vm = virtualMachine else {
			throw err(msg: "Failed to create VM from configuration")
		}

		let size = VMConfig.mainScreenSize(2560, 1440)

		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)

		// Create a VMView with the new controller.
		let view = VMView(vm: vm)
		// Create a new NSWindow and host the VMView.

		window.center()
		window.title = config.name
		window.contentView = NSHostingView(rootView: view)
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
					self.log(error: "Failed to start \(self.config.name): \(error)")
				case .success:
					try? self.config.start(window: window)
					self.viewModel?.forceUpdate()
					break;
				}
			}
		}
	}
	static func blackImage(size: NSSize) -> NSImage {
		let image = NSImage(size: size)
		image.lockFocus()
		NSColor.black.setFill()
		NSRect(origin: .zero, size: size).fill()
		image.unlockFocus()
		return image
	}

	func captureWindowImage(completion: @escaping (NSImage) -> Void) {
		Task {
			do {
				// 1. Get list of shareable windows
				let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
				guard let window = self.config.window else {
					print("captureWindowImage: no window")
					completion(VirtualMachine.blackImage(size: NSSize(width: 300, height: 200)))
					return
				}

				// 2. Match our window
				let windowID: CGWindowID = await MainActor.run {
					CGWindowID(window.windowNumber)
				}

				guard let targetWindow = content.windows.first(where: {
					$0.windowID == windowID
				}) else {
					print("captureWindowImage: Window not found in shareable content")
					completion(VirtualMachine.blackImage(size: NSSize(width: 300, height: 200)))
					return
				}

				// 3. Set up capture config
				let config = SCStreamConfiguration()
				let size = targetWindow.frame.size
				config.width = Int(size.width)
				config.height = Int(size.height)

				// 4. Filter just this window
				let filter = SCContentFilter(desktopIndependentWindow: targetWindow)

				// 5. Grab a single frame
				let frameGrabber = FrameGrabber { image in
					if let image = image {
						completion(image)
					} else {
						completion(VirtualMachine.blackImage(size: NSSize(width: 300, height: 200)))
					}
				}

				let stream = SCStream(filter: filter, configuration: config, delegate: nil)
				try stream.addStreamOutput(frameGrabber, type: .screen, sampleHandlerQueue: .main)
				try await stream.startCapture()
			} catch {
				print("captureWindowImage: Capture error: \(error)")
				completion(VirtualMachine.blackImage(size: NSSize(width: 300, height: 200)))
			}
		}
	}

	func stopVM() {
		guard let vm = virtualMachine else {
			log(warning: "No VM is running.")
			return
		}

		vm.stop { error in
			DispatchQueue.main.async {
				if let error = error {
					self.log(error:"Failed to stop VM: \(self.config.name): \(error)")
				} else {
					self.log(message: "VM: \(self.config.name) stopped successfully.")
				}
			}
		}

		try? self.config.stop()
		self.config.window = nil
		self.virtualMachine = nil
		viewModel?.onStopped()
		viewModel?.forceUpdate()
	}

	func onStop() {
		if self.config.state != .stopped {
			viewModel?.onStopped()
			try? self.config.stop()
			self.viewModel?.forceUpdate()
			self.log(message: "window closed and \(self.config.name) stopped successfully.")
			self.virtualMachine = nil
		}
	}

	@objc func windowDidClose(notification: Notification) {
		DispatchQueue.main.async {
			if self.config.state != .stopped {
				self.stopVM()
			}
		}
	}

	func guestDidStop(_ virtualMachine: VZVirtualMachine) {
		DispatchQueue.main.async { self.onStop() }
	}

	func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
		DispatchQueue.main.async { self.onStop() }
	}
}
class FrameGrabber: NSObject, SCStreamOutput {
	private var didCapture = false
	private let callback: (NSImage?) -> Void

	init(callback: @escaping (NSImage?) -> Void) {
		self.callback = callback
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
		guard !didCapture,
			let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
			return
		}

		didCapture = true

		let ciImage = CIImage(cvImageBuffer: imageBuffer)
		let rep = NSCIImageRep(ciImage: ciImage)
		let nsImage = NSImage(size: rep.size)
		nsImage.addRepresentation(rep)

		callback(nsImage)
	}
}
