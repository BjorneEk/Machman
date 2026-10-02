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

	@Test func aCanceledInstallSaysSo() {
		#expect(MacInstaller.failedReason(for: URLError(.cancelled), cancelled: true)
			== "The macOS install was canceled.")
	}

	@Test func theErrorEventSaysItInWords() {
		#expect(InstallSession.failureEvent(for: vzError)
			== "The macOS install failed: Installation failed. A software update is required "
				+ "to complete the installation.")
	}
}
