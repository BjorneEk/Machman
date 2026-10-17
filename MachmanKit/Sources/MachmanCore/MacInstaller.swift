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
import MachmanAPI

@MainActor
final class MacInstaller {
	// The downloaded image's holding name inside the VM dir — install input only, removed
	// by the in-process defer; anything found between installs is crash residue (the
	// startup sweep and the copier's skip list both key off this name).
	nonisolated static let restoreImageFileName = "restore.ipsw"

	enum Source {
		case localIPSW(URL)
		case latestSupported
	}

	let config: VMConfig
	private(set) var progress: Progress?
	private var downloadTask: URLSessionDownloadTask?
	private(set) var cancelled = false

	// What a failed install stores as its reason, which the canvas and the Activity list
	// show (H31): the error's own sentence, never an NSError dump.
	nonisolated static func failedReason(for error: Error, cancelled: Bool) -> String {
		cancelled ? "The macOS install was canceled." : MachmanError.userMessage(for: error)
	}

	// Whether `error` is how a cancel ends a stage: a download task's URLError.cancelled, a
	// Cocoa user cancel, Swift's CancellationError, or — once VZMacOSInstaller runs, where
	// cancel() cancels its progress — Virtualization's operationCancelled (F10).
	nonisolated static func isCancellation(_ error: Error) -> Bool {
		if error is CancellationError || (error as? URLError)?.code == .cancelled {
			return true
		}
		let ns = error as NSError
		if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
		return ns.domain == VZError.errorDomain
			&& ns.code == VZError.Code.operationCancelled.rawValue
	}

	// Apple's latest image is newer than this Mac can install (the index was unreachable).
	nonisolated static func needsNewerHostReason(_ version: String) -> String {
		"macOS \(version) needs a newer macOS on this Mac — update this Mac, or install an "
			+ "older version from an IPSW file"
	}

	// The download ended at a size other than the index's, in the units every size uses
	// (decision 14). Sizes that round alike would read "13.4 GB of 13.4 GB", and an unread
	// size (-1) is no size at all, so those say it without numbers.
	nonisolated static func incompleteDownloadReason(size: Int64, expected: Int64) -> String {
		let got = ByteSize.display(UInt64(clamping: max(size, 0)))
		let want = ByteSize.display(UInt64(clamping: max(expected, 0)))
		guard size >= 0, size < expected, got != want else {
			return "The downloaded restore image isn’t the expected size"
		}
		return "The restore image download stopped at \(got) of \(want)"
	}

	// A download answered with an error status (a 403 or 404 page) failed: its body is no
	// restore image (D27). nil for a 2xx, or for a response that isn't HTTP.
	nonisolated static func downloadFailure(for response: URLResponse?) -> Error? {
		guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode)
		else { return nil }
		return VirtualMachineError.critical(
			"The restore image download failed with HTTP status \(http.statusCode)")
	}

	// Stage callbacks for a UI controller.
	var onResolved: ((_ version: String, _ build: String) -> Void)?
	var onDownloadProgress: ((Progress) -> Void)?
	var onInstallProgress: ((Progress) -> Void)?

	init(config: VMConfig) {
		self.config = config
	}

	// The downloaded image's last move, into the VM folder (D33): a rename on the library's
	// own volume, a ~13 GB copy onto one elsewhere (the MachmanDataDir override). A seam for
	// tests; download(from:to:) runs it off the main actor.
	var placeDownload: @Sendable (_ holding: URL, _ local: URL) throws -> Void = { holding, local in
		if FileManager.default.fileExists(atPath: local.path) {
			try FileManager.default.removeItem(at: local)
		}
		try FileManager.default.moveItem(at: holding, to: local)
	}

	func install(source: Source) async throws {
		// An install replaces the boot mode, so never one a newer Machman wrote (C11), and it
		// boots the VM, so never with a disk one added still enabled (D38).
		try config.requireStartable()
		// An install restores over the system disk and rewrites the platform identity and
		// aux storage (which now overwrites, E24): never on a Mac that is installed. The UI
		// only offers it before that; this guards every other caller.
		guard !config.boot.isMacInstalled else {
			throw MachmanError(
				code: .invalidState, message: "macOS is already installed on \(config.name)")
		}
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
		// The last stage boundary: from here to installer.install() nothing awaits, so a
		// cancel can't land in between.
		try throwIfCancelled()
		guard let requirements = image.mostFeaturefulSupportedConfiguration else {
			throw VirtualMachineError.critical("This Mac can’t install that restore image")
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
			// No serial bridges during install (nothing would drain the pipes).
			let built = try config.makeVZVirtualMachineConfiguration(attachSerial: false)
			let vm = VZVirtualMachine(configuration: built.configuration)
			let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: image.url)
			self.progress = installer.progress
			onInstallProgress?(installer.progress)
			try await installer.install()
		} catch {
			let reason = Self.failedReason(
				for: error, cancelled: cancelled || Self.isCancellation(error))
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

	// A cancel that lands between stages — while the index loads, or between the download
	// and the installer — has no task or progress to cancel, so each stage boundary reads
	// the flag instead (F12).
	private func throwIfCancelled() throws {
		if cancelled { throw CocoaError(.userCancelled) }
	}

	// MARK: - Restore image resolution

	// Index of all VirtualMac restore images. A third party's index, so an entry's download
	// url is taken only when it is https on Apple's own hosts (trustedDownload, D27).
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

	// Apple's update hosts: https on apple.com or cdn-apple.com, or a subdomain of either
	// (updates.cdn-apple.com serves the restore images).
	nonisolated static func isAppleRestoreImageURL(_ url: URL) -> Bool {
		guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
			return false
		}
		return ["apple.com", "cdn-apple.com"].contains { host == $0 || host.hasSuffix("." + $0) }
	}

	// The index entry to download: the newest this host can install, when its url is one of
	// Apple's. nil falls back to Apple's own "latest supported" — a spoofed or compromised
	// entry never steers the download (D27).
	nonisolated static func trustedDownload(
		in index: RestoreImageIndex, host: OperatingSystemVersion
	) -> (firmware: RestoreImageIndex.Firmware, url: URL)? {
		guard let firmware = newestCompatible(in: index, host: host),
			let url = URL(string: firmware.url) else { return nil }
		guard isAppleRestoreImageURL(url) else {
			MachmanLogger.log(.passiveWarning,
				"restore image index: skipped \(firmware.url), not an https URL on Apple’s hosts")
			return nil
		}
		return (firmware, url)
	}

	private static func fetchRestoreImageIndex() async throws -> RestoreImageIndex {
		let (data, _) = try await URLSession.shared.data(from: restoreImageIndexURL)
		return try JSONDecoder().decode(RestoreImageIndex.self, from: data)
	}

	// Returns the resolved image plus, for the remote path, the downloaded file (which the
	// caller must remove once the install is over).
	private func resolveRestoreImage(
		_ source: Source) async throws -> (image: VZMacOSRestoreImage, downloaded: URL?) {
		try throwIfCancelled()
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
				let download = Self.trustedDownload(in: index, host: host) {
				onResolved?(download.firmware.version, download.firmware.buildid)
				return try await downloadAndLoad(
					from: download.url, expectedSize: download.firmware.filesize)
			}
			// Fallback (index unreachable, or its entry not on Apple's hosts): Apple's
			// hardware-filtered "latest supported", with an early host-version check so a
			// too-new image fails BEFORE the multi-GB download.
			let remote = try await Self.fetchLatestSupported()
			let version = remote.operatingSystemVersion
			guard Self.isVersion(version, atMost: host) else {
				throw VirtualMachineError.critical(
					Self.needsNewerHostReason(Self.versionString(version)))
			}
			onResolved?(Self.versionString(version), remote.buildVersion)
			return try await downloadAndLoad(from: remote.url)
		}
	}

	private func downloadAndLoad(
		from remote: URL, expectedSize: Int64? = nil) async throws -> (VZMacOSRestoreImage, URL) {
		let localURL = URL(
			fileURLWithPath: config.configFilePath(file: Self.restoreImageFileName))
		try await download(from: remote, to: localURL)
		do {
			if let expectedSize = expectedSize {
				let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
				let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
				guard size == expectedSize else {
					// The log keeps the exact byte counts.
					MachmanLogger.log(.passiveError,
						"restore image download: \(size) of \(expectedSize) bytes")
					throw VirtualMachineError.critical(
						Self.incompleteDownloadReason(size: size, expected: expectedSize))
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
	// holding location inside the handler (the same volume: a rename). The last move, into the
	// VM folder, runs detached — never on the main actor, which answers every client (D33).
	func download(from remote: URL, to local: URL) async throws {
		try throwIfCancelled()   // the index or Apple's lookup may have taken a while
		let holding: URL = try await withCheckedThrowingContinuation { continuation in
			let task = URLSession.shared.downloadTask(with: remote) { url, response, error in
				if let error = error {
					continuation.resume(throwing: error)
					return
				}
				if let failure = Self.downloadFailure(for: response) {
					continuation.resume(throwing: failure)
					return
				}
				guard let url = url else {
					continuation.resume(
						throwing: VirtualMachineError.critical("The download produced no file"))
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
		let place = placeDownload
		try await Task.detached(priority: .utility) { try place(holding, local) }.value
	}
}
