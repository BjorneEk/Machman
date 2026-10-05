//
//  DaemonVersionPrompt.swift
//  MachmanDesktopCore
//
//  What the desktop says when the running Machman Agent is older than its floor (X7, W4),
//  and when that agent can't be replaced yet: one sentence each, "Machman Agent" never
//  "daemon". A value, so the texts are testable; DaemonConnection turns it into the alert.
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

	// The old agent refused to be replaced while it runs work of its own (E45); `reason` is
	// its refusal, which names the work and has no period of its own.
	public static func replaceRefused(reason: String) -> DaemonVersionPrompt {
		DaemonVersionPrompt(
			title: "Machman Agent can’t be replaced yet", message: reason + ".",
			buttons: ["OK"])
	}
}
