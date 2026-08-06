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
		let (image, downloaded) = try await resolveRestoreImage(source)
		defer {
			// A downloaded restore image is install input only — never leave it behind,
			// whether the install succeeded or failed.
			if let downloaded = downloaded {
				try? FileManager.default.removeItem(at: downloaded)
			}
		}
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

	// Index of all VirtualMac restore images. Third-party INDEX only — the listed download
	// urls point at Apple's own CDN (updates.cdn-apple.com).
	struct RestoreImageIndex: Codable {
		struct Firmware: Codable {
			var version: String
			var buildid: String
			var url: String
			var filesize: Int64
		}
		var firmwares: [Firmware]
	}

	static let restoreImageIndexURL =
		URL(string: "https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw")!

	nonisolated static func versionString(_ v: OperatingSystemVersion) -> String {
		v.patchVersion == 0
			? "\(v.majorVersion).\(v.minorVersion)"
			: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
	}

	nonisolated static func parseVersion(_ s: String) -> OperatingSystemVersion? {
		let parts = s.split(separator: ".").map { Int($0) }
		guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
		return OperatingSystemVersion(
			majorVersion: parts[0] ?? 0,
			minorVersion: parts.count > 1 ? (parts[1] ?? 0) : 0,
			patchVersion: parts.count > 2 ? (parts[2] ?? 0) : 0)
	}

	nonisolated static func versionLess(
		_ a: OperatingSystemVersion, _ b: OperatingSystemVersion) -> Bool {
		if a.majorVersion != b.majorVersion { return a.majorVersion < b.majorVersion }
		if a.minorVersion != b.minorVersion { return a.minorVersion < b.minorVersion }
		return a.patchVersion < b.patchVersion
	}

	nonisolated static func isVersion(
		_ a: OperatingSystemVersion, atMost b: OperatingSystemVersion) -> Bool {
		!versionLess(b, a)
	}

	// Newest image installable on a host running `host` (conservative rule: guest <= host —
	// a newer guest fails at install time with VZError 10006 installationRequiresUpdate).
	nonisolated static func newestCompatible(
		in index: RestoreImageIndex,
		host: OperatingSystemVersion) -> RestoreImageIndex.Firmware? {
		let candidates = index.firmwares
			.compactMap { fw -> (RestoreImageIndex.Firmware, OperatingSystemVersion)? in
				guard let v = parseVersion(fw.version), isVersion(v, atMost: host) else {
					return nil
				}
				return (fw, v)
			}
		return candidates.max { versionLess($0.1, $1.1) }?.0
	}

	private static func fetchRestoreImageIndex() async throws -> RestoreImageIndex {
		let (data, _) = try await URLSession.shared.data(from: restoreImageIndexURL)
		return try JSONDecoder().decode(RestoreImageIndex.self, from: data)
	}

	// Returns the resolved image plus, for the remote path, the downloaded file (which the
	// caller must remove once the install is over).
	private func resolveRestoreImage(
		_ source: Source) async throws -> (image: VZMacOSRestoreImage, downloaded: URL?) {
		switch source {
		case .localIPSW(let url):
			let image = try await VZMacOSRestoreImage.image(from: url)
			onResolved?(Self.versionString(image.operatingSystemVersion), image.buildVersion)
			return (image, nil)
		case .latestSupported:
			let host = ProcessInfo.processInfo.operatingSystemVersion
			// Prefer the index: it lets us pick the newest version this HOST can install, not
			// just the newest for the hardware (which fails late with VZError 10006).
			if let index = try? await Self.fetchRestoreImageIndex(),
				let firmware = Self.newestCompatible(in: index, host: host),
				let remote = URL(string: firmware.url) {
				onResolved?(firmware.version, firmware.buildid)
				return try await downloadAndLoad(from: remote, expectedSize: firmware.filesize)
			}
			// Fallback (index unreachable): Apple's hardware-filtered "latest supported", with
			// an early host-version check so a too-new image fails BEFORE the multi-GB download.
			let remote = try await Self.fetchLatestSupported()
			let version = remote.operatingSystemVersion
			guard Self.isVersion(version, atMost: host) else {
				throw VirtualMachineError.critical(
					"macOS \(Self.versionString(version)) requires a newer host. "
					+ "Update macOS or install an older version from a local .ipsw")
			}
			onResolved?(Self.versionString(version), remote.buildVersion)
			return try await downloadAndLoad(from: remote.url)
		}
	}

	private func downloadAndLoad(
		from remote: URL, expectedSize: Int64? = nil) async throws -> (VZMacOSRestoreImage, URL) {
		let localURL = URL(fileURLWithPath: config.configFilePath(file: "restore.ipsw"))
		try await download(from: remote, to: localURL)
		do {
			if let expectedSize = expectedSize {
				let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
				let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
				guard size == expectedSize else {
					throw VirtualMachineError.critical(
						"Restore image download incomplete (\(size) of \(expectedSize) bytes)")
				}
			}
			let image = try await VZMacOSRestoreImage.image(from: localURL)
			return (image, localURL)
		} catch {
			try? FileManager.default.removeItem(at: localURL)   // corrupt/incomplete download
			throw error
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
		// If the final move fails, don't leak the holding file (no-op after a successful move).
		defer { try? FileManager.default.removeItem(at: holding) }
		if FileManager.default.fileExists(atPath: local.path) {
			try FileManager.default.removeItem(at: local)
		}
		try FileManager.default.moveItem(at: holding, to: local)
	}
}
