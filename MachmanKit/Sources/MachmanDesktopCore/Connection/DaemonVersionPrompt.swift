//
//  DaemonVersionPrompt.swift
//  MachmanDesktopCore
//
//  What the desktop says when the running Machman Agent is older than its floor (X7, W4):
//  one sentence each, "Machman Agent" never "daemon". A value, so the texts are testable;
//  DaemonConnection turns it into the alert.
//

import Foundation

public struct DaemonVersionPrompt: Equatable, Sendable {
	public let title: String
	public let message: String
	public let buttons: [String]

	// canReplace: this app embeds a newer agent it can start in the old one's place.
	public static func tooOld(running: String, floor: String, canReplace: Bool)
		-> DaemonVersionPrompt {
		canReplace
			? DaemonVersionPrompt(
				title: "The running Machman Agent is too old",
				message: "It runs version \(running) and this app needs \(floor) or newer — "
					+ "replacing it keeps your VMs running.",
				buttons: ["Replace", "Not Now"])
			: DaemonVersionPrompt(
				title: "Machman Agent is too old",
				message: "Version \(running) is running, but this app needs \(floor) or newer "
					+ "— reinstall Machman to update it.",
				buttons: ["OK"])
	}
}
