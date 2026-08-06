//
//  ConsolePresenter.swift
//  Machman
//
//  Owns console windows and their capture. This is the one component that can never move to a
//  client process: VZVirtualMachineView must live in the process that owns the VZVirtualMachine,
//  so windows are presented here, engine-side, and clients only send commands about them.
//
//  Closing a window invokes closeHandler (the registry decides what happens to the VM);
//  dropConsole closes programmatically without triggering it.
//

import AppKit
import SwiftUI
import Virtualization
import ScreenCaptureKit
import CoreMedia

@MainActor
final class ConsolePresenter: NSObject {
	private var windows: [String: NSWindow] = [:]
	private var observers: [String: NSObjectProtocol] = [:]
	// Invoked when the *user* closes a console window.
	var closeHandler: ((String) -> Void)?

	func openConsole(name: String, vz: VZVirtualMachine) {
		if let existing = windows[name] {
			existing.makeKeyAndOrderFront(nil)
			return
		}
		let size = VMConfig.mainScreenSize(2560, 1440)
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.center()
		window.title = name
		window.contentView = NSHostingView(rootView: VMView(vm: vz))
		window.makeKeyAndOrderFront(nil)
		window.isReleasedWhenClosed = false
		windows[name] = window
		observers[name] = NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification, object: window, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.userClosed(name)
			}
		}
	}

	// Close and forget without invoking the close handler (the VM went away on its own).
	func dropConsole(name: String) {
		guard let window = windows[name] else { return }
		forget(name)
		window.close()
	}

	func window(for name: String) -> NSWindow? {
		windows[name]
	}

	private func userClosed(_ name: String) {
		guard windows[name] != nil else { return }
		forget(name)
		closeHandler?(name)
	}

	private func forget(_ name: String) {
		if let token = observers.removeValue(forKey: name) {
			NotificationCenter.default.removeObserver(token)
		}
		windows[name] = nil
	}

	// MARK: - Window capture (previews)

	static func blackImage(size: NSSize) -> NSImage {
		let image = NSImage(size: size)
		image.lockFocus()
		NSColor.black.setFill()
		NSRect(origin: .zero, size: size).fill()
		image.unlockFocus()
		return image
	}

	// One frame of the console window via ScreenCaptureKit. Always resolves (black fallback):
	// the stream is stopped after the first frame and a timeout guards against hangs.
	func captureImage(name: String) async -> NSImage {
		let fallback = Self.blackImage(size: NSSize(width: 300, height: 200))
		guard let window = windows[name] else { return fallback }
		let windowID = CGWindowID(window.windowNumber)
		guard let content = try? await SCShareableContent
			.excludingDesktopWindows(false, onScreenWindowsOnly: true),
			let target = content.windows.first(where: { $0.windowID == windowID }) else {
			return fallback
		}
		let config = SCStreamConfiguration()
		config.width = Int(target.frame.width)
		config.height = Int(target.frame.height)
		let filter = SCContentFilter(desktopIndependentWindow: target)
		let stream = SCStream(filter: filter, configuration: config, delegate: nil)
		return await withCheckedContinuation { continuation in
			let once = OneShotImage(continuation: continuation, fallback: fallback)
			let grabber = FrameGrabber { image in
				once.resume(image)
			}
			once.retain(stream: stream, grabber: grabber)
			do {
				try stream.addStreamOutput(grabber, type: .screen, sampleHandlerQueue: .main)
				stream.startCapture { error in
					if error != nil {
						once.resume(nil)
					}
				}
			} catch {
				once.resume(nil)
			}
			Task {
				try? await Task.sleep(for: .seconds(5))
				once.resume(nil)
			}
		}
	}
}

// Resolves a capture continuation exactly once and keeps the stream + grabber alive until then.
private final class OneShotImage: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<NSImage, Never>?
	private let fallback: NSImage
	private var stream: SCStream?
	private var grabber: FrameGrabber?

	init(continuation: CheckedContinuation<NSImage, Never>, fallback: NSImage) {
		self.continuation = continuation
		self.fallback = fallback
	}

	func retain(stream: SCStream, grabber: FrameGrabber) {
		lock.lock()
		defer { lock.unlock() }
		guard continuation != nil else { return }
		self.stream = stream
		self.grabber = grabber
	}

	func resume(_ image: NSImage?) {
		lock.lock()
		let cont = continuation
		continuation = nil
		let stream = self.stream
		self.stream = nil
		self.grabber = nil
		lock.unlock()
		guard let cont = cont else { return }
		stream?.stopCapture { _ in }
		cont.resume(returning: image ?? fallback)
	}
}

private final class FrameGrabber: NSObject, SCStreamOutput {
	private var didCapture = false
	private let callback: (NSImage?) -> Void

	init(callback: @escaping (NSImage?) -> Void) {
		self.callback = callback
	}

	func stream(
		_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
		of outputType: SCStreamOutputType
	) {
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
