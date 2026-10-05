//
//  MacInstallFailureTextTests.swift
//  MachmanTests
//
//  H31: a failed macOS install stored "\(error)" as its reason, so the canvas label read
//  "Error Domain=VZErrorDomain Code=10007 …". It stores the error's own sentence now, and the
//  error event says it in words (the log keeps the NSError).
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

struct MacInstallFailureTextTests {
	// Samples.macOSFailedInstall's error, as Virtualization reports it.
	private let vzError = NSError(domain: "VZErrorDomain", code: 10007, userInfo: [
		NSLocalizedDescriptionKey: "Installation failed.",
		NSLocalizedFailureReasonErrorKey:
			"A software update is required to complete the installation.",
	])

	@Test func aFailedInstallStoresItsReason() {
		let reason = MacInstaller.failedReason(for: vzError, cancelled: false)
		#expect(reason
			== "Installation failed. A software update is required to complete the installation.")
		#expect(reason == Samples.macOSFailedInstallReadable().boot.macInstallState?.message)
		#expect(MacInstaller.failedReason(
			for: MachmanError(code: .installFailure, message: "x"), cancelled: false) == "x")
	}

	// D27: the download never looked at the HTTP status, so a 403/404 page was taken as the
	// image and then reported as "The restore image download stopped at 1 KB of 13.4 GB" —
	// an interrupted download it wasn't.
	@Test func anErrorStatusIsItsOwnFailure() throws {
		let url = try #require(URL(string: "https://updates.cdn-apple.com/x/Restore.ipsw"))
		func response(_ status: Int) -> HTTPURLResponse? {
			HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
		}
		let failure = try #require(MacInstaller.downloadFailure(for: response(404)))
		#expect(MachmanError.userMessage(for: failure)
			== "The restore image download failed with HTTP status 404")
		for fine in [200, 206] {
			#expect(MacInstaller.downloadFailure(for: response(fine)) == nil)
		}
		#expect(MacInstaller.downloadFailure(for: nil) == nil)
		#expect(MacInstaller.downloadFailure(for: URLResponse(
			url: URL(fileURLWithPath: "/x.ipsw"), mimeType: nil, expectedContentLength: 0,
			textEncodingName: nil)) == nil)
	}

	@Test func aCanceledInstallSaysSo() {
		#expect(MacInstaller.failedReason(for: URLError(.cancelled), cancelled: true)
			== "The macOS install was canceled.")
	}

	// R4-1: was two sentences naming "a newer host" and "a local .ipsw".
	@Test func aTooNewImageSaysUpdateThisMac() {
		let reason = MacInstaller.needsNewerHostReason("15.4")
		#expect(reason == "macOS 15.4 needs a newer macOS on this Mac — update this Mac, or "
			+ "install an older version from an IPSW file")
		#expect(InstallSession.failureEvent(for: VirtualMachineError.critical(reason))
			== "The macOS install failed: " + reason)
	}

	// R4-1: was "Restore image download incomplete (… of … bytes)".
	@Test func aShortDownloadSaysHowFarItGot() {
		let gib: Int64 = 1 << 30
		#expect(MacInstaller.incompleteDownloadReason(size: 3 * gib, expected: 13 * gib)
			== "The restore image download stopped at 3 GB of 13 GB")
		// A few bytes short would read "13 GB of 13 GB"; longer, or an unread size (-1),
		// is no "stopped at" either: those say it without numbers.
		let noNumbers = "The downloaded restore image isn’t the expected size"
		#expect(MacInstaller.incompleteDownloadReason(size: 13 * gib - 4096, expected: 13 * gib)
			== noNumbers)
		#expect(MacInstaller.incompleteDownloadReason(size: 14 * gib, expected: 13 * gib)
			== noNumbers)
		#expect(MacInstaller.incompleteDownloadReason(size: -1, expected: 13 * gib) == noNumbers)
	}

	@Test func theErrorEventSaysItInWords() {
		#expect(InstallSession.failureEvent(for: vzError)
			== "The macOS install failed: Installation failed. A software update is required "
				+ "to complete the installation.")
	}
}
