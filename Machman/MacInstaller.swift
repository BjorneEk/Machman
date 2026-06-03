//
//  MacInstaller.swift
//  Machman
//
//  Drives a macOS guest install: resolve a restore image (local .ipsw, or the latest supported
//  downloaded from Apple), create the platform artifacts + system disk, then run VZMacOSInstaller.
//  The VM's boot state is .macOS(.installing) for the duration, so an interrupted install is
//  detectable on the next load. Not yet reachable from the GUI.
//
//  Note: VZVirtualMachine work is expected on the main thread; when this is wired to the GUI the
//  install path should run main-actor isolated. It is dormant for now.
//

import Foundation
import Virtualization

final class MacInstaller {
	enum Source {
		case localIPSW(URL)
		case latestSupported
	}

	let config: VMConfig
	private(set) var progress: Progress?

	init(config: VMConfig) {
		self.config = config
	}

	func install(source: Source) async throws {
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
			try await installer.install()
		} catch {
			config.boot = .macOS(MacOSBoot(installState: .failed("\(error)"),
				minimumCPUCount: minCPU, minimumMemorySize: minMem))
			try? config.saveVMConfig()
			throw error
		}

		config.boot = .macOS(MacOSBoot(installState: .installed,
			minimumCPUCount: minCPU, minimumMemorySize: minMem))
		try config.saveVMConfig()
	}

	func cancel() {
		progress?.cancel()
	}

	// MARK: - Restore image resolution

	private func resolveRestoreImage(_ source: Source) async throws -> VZMacOSRestoreImage {
		switch source {
		case .localIPSW(let url):
			return try await VZMacOSRestoreImage.image(from: url)
		case .latestSupported:
			let remote = try await Self.fetchLatestSupported()
			let localURL = URL(fileURLWithPath: config.configFilePath(file: "restore.ipsw"))
			try await Self.download(from: remote.url, to: localURL)
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

	private static func download(from remote: URL, to local: URL) async throws {
		let (tempURL, _) = try await URLSession.shared.download(from: remote)
		if FileManager.default.fileExists(atPath: local.path) {
			try FileManager.default.removeItem(at: local)
		}
		try FileManager.default.moveItem(at: tempURL, to: local)
	}
}
