//
//  MacInstaller.swift
//  Machman
//
//  Drives a macOS guest install: resolve a restore image (local .ipsw, or the latest supported
//  downloaded from Apple), create the platform artifacts + system disk, then run VZMacOSInstaller.
//  The VM's boot state is .macOS(.installing) for the duration, so an interrupted install is
//  detectable on the next load. UI-agnostic: stages are reported through the on* callbacks
//  (consumed by MacInstallController). Main-actor because VZVirtualMachine work belongs there.
//

import Foundation
import Virtualization

@MainActor
final class MacInstaller {
	enum Source {
		case localIPSW(URL)
		case latestSupported
	}

	let config: VMConfig
	private(set) var progress: Progress?
	private var downloadTask: URLSessionDownloadTask?
	private var cancelled = false

	// Stage callbacks for a UI controller.
	var onResolved: ((_ version: String, _ build: String) -> Void)?
	var onDownloadProgress: ((Progress) -> Void)?
	var onInstallProgress: ((Progress) -> Void)?

	init(config: VMConfig) {
		self.config = config
	}

	func install(source: Source) async throws {
		// Resolve (and for .latestSupported, download) before touching any VM state, so a
		// cancelled or failed download leaves the original boot mode untouched.
		let image = try await resolveRestoreImage(source)
		guard let requirements = image.mostFeaturefulSupportedConfiguration else {
			throw VirtualMachineError.critical("Restore image is not supported on this host")
		}
		let hwModel = requirements.hardwareModel
		let minCPU = requirements.minimumSupportedCPUCount
		let minMem = requirements.minimumSupportedMemorySize

		// Persist platform identity + a system disk before building the VM.
		try config.persistMacHardwareModel(hwModel)
		try config.createMacMachineIdentifier()
		try config.createMacAuxiliaryStorage(hardwareModel: hwModel)
		try config.ensureMacSystemDisk()
		if config.cpuCount < minCPU { config.cpuCount = minCPU }
		if config.memorySize < minMem { config.memorySize = minMem }

		config.boot = .macOS(MacOSBoot(installState: .installing,
			minimumCPUCount: minCPU, minimumMemorySize: minMem))
		try config.saveVMConfig()

		do {
			let vmConfig = try config.makeVZVirtualMachineConfiguration()
			let vm = VZVirtualMachine(configuration: vmConfig)
			let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: image.url)
			self.progress = installer.progress
			onInstallProgress?(installer.progress)
			try await installer.install()
		} catch {
			let reason = cancelled ? "cancelled by user" : "\(error)"
			config.boot = .macOS(MacOSBoot(installState: .failed(reason),
				minimumCPUCount: minCPU, minimumMemorySize: minMem))
			try? config.saveVMConfig()
			throw error
		}

		config.boot = .macOS(MacOSBoot(installState: .installed,
			minimumCPUCount: minCPU, minimumMemorySize: minMem))
		try config.saveVMConfig()
	}

	func cancel() {
		cancelled = true
		downloadTask?.cancel()
		progress?.cancel()
	}

	// MARK: - Restore image resolution

	static func versionString(_ v: OperatingSystemVersion) -> String {
		v.patchVersion == 0
			? "\(v.majorVersion).\(v.minorVersion)"
			: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
	}

	private func resolveRestoreImage(_ source: Source) async throws -> VZMacOSRestoreImage {
		switch source {
		case .localIPSW(let url):
			let image = try await VZMacOSRestoreImage.image(from: url)
			onResolved?(Self.versionString(image.operatingSystemVersion), image.buildVersion)
			return image
		case .latestSupported:
			let remote = try await Self.fetchLatestSupported()
			onResolved?(Self.versionString(remote.operatingSystemVersion), remote.buildVersion)
			let localURL = URL(fileURLWithPath: config.configFilePath(file: "restore.ipsw"))
			try await download(from: remote.url, to: localURL)
			return try await VZMacOSRestoreImage.image(from: localURL)
		}
	}

	private static func fetchLatestSupported() async throws -> VZMacOSRestoreImage {
		try await withCheckedThrowingContinuation { continuation in
			VZMacOSRestoreImage.fetchLatestSupported { result in
				continuation.resume(with: result)
			}
		}
	}

	// Downloads with a task whose Progress is surfaced through onDownloadProgress. The system
	// deletes the downloaded temp file when the completion handler returns, so it is moved to a
	// holding location inside the handler.
	private func download(from remote: URL, to local: URL) async throws {
		let holding: URL = try await withCheckedThrowingContinuation { continuation in
			let task = URLSession.shared.downloadTask(with: remote) { url, _, error in
				if let error = error {
					continuation.resume(throwing: error)
					return
				}
				guard let url = url else {
					continuation.resume(
						throwing: VirtualMachineError.critical("Download produced no file"))
					return
				}
				do {
					let holding = FileManager.default.temporaryDirectory
						.appendingPathComponent(UUID().uuidString)
					try FileManager.default.moveItem(at: url, to: holding)
					continuation.resume(returning: holding)
				} catch {
					continuation.resume(throwing: error)
				}
			}
			self.downloadTask = task
			onDownloadProgress?(task.progress)
			task.resume()
		}
		if FileManager.default.fileExists(atPath: local.path) {
			try FileManager.default.removeItem(at: local)
		}
		try FileManager.default.moveItem(at: holding, to: local)
	}
}
