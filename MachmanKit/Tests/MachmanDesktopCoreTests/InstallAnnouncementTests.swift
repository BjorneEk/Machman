//
//  InstallAnnouncementTests.swift
//  MachmanDesktopCoreTests
//
//  F16: a macOS install's corner card shows only while it resolves, downloads or installs,
//  and simply leaves when the phase ends — so a 30-minute install finished, or failed,
//  without a word to VoiceOver. Its card now leaves saying the outcome, once: Installed,
//  Failed with the reason (urgent), Interrupted (urgent), Canceled. The hosted half (the
//  overlay posts it) is ToastCardTests'.
//

import Testing
import MachmanAPI
import MachmanUI
@testable import MachmanDesktopCore

struct InstallAnnouncementTests {
	private static let installing = InstallPhase(kind: .installing, version: "15.4")

	private static func said(
		_ old: InstallPhase?, _ new: InstallPhase?, vm: String = "Sequoia"
	) -> [ToastAnnouncement] {
		InstallPhase.announcements(
			from: old.map { [vm: $0] } ?? [:], to: new.map { [vm: $0] } ?? [:])
	}

	@Test("H56: an install's card leaves saying Installed, or Failed with its reason")
	func anEndedInstallSaysItsOutcome() {
		#expect(Self.said(Self.installing, InstallPhase(kind: .installed)) == [
			ToastAnnouncement(text: "Sequoia — Installing macOS: Installed", urgent: false),
		])
		let failed = InstallPhase(kind: .failed, message: "The restore image is damaged")
		#expect(Self.said(Self.installing, failed) == [
			ToastAnnouncement(
				text: "Sequoia — Installing macOS: Failed — The restore image is damaged",
				urgent: true),
		])
		#expect(Self.said(InstallPhase(kind: .downloading), InstallPhase(kind: .failed))
			.map(\.text) == ["Sequoia — Installing macOS: Failed"])
		#expect(Self.said(InstallPhase(kind: .resolving), InstallPhase(kind: .interrupted))
			== [ToastAnnouncement(text: "Sequoia — Installing macOS: Interrupted", urgent: true)])
		// A cancel puts the phase back where the VM's state says.
		#expect(Self.said(Self.installing, InstallPhase(kind: .idle)).map(\.text)
			== ["Sequoia — Installing macOS: Canceled"])
	}

	@Test("H56: only a card that leaves says anything, and only once")
	func onlyALeavingCardSpeaks() {
		// Still running, moving between running phases, or first seen: the card shows it.
		#expect(Self.said(Self.installing, Self.installing).isEmpty)
		#expect(Self.said(InstallPhase(kind: .downloading), Self.installing).isEmpty)
		#expect(Self.said(nil, Self.installing).isEmpty)
		// An ended install seen again, or primed already ended: no card ever showed.
		let installed = InstallPhase(kind: .installed)
		#expect(Self.said(installed, installed).isEmpty)
		#expect(Self.said(nil, installed).isEmpty)
		// A VM gone, or a reconnect that starts the phases over: nothing ended here.
		#expect(Self.said(Self.installing, nil).isEmpty)
		// The card's title is the one the overlay draws.
		#expect(InstallPhase.cardTitle(vm: "Sequoia") == "Sequoia — Installing macOS")
	}
}
