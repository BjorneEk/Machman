//
//  ToastAnnouncementTests.swift
//  MachmanUITests
//
//  H56: what VoiceOver hears of the bottom-right corner. A toast is announced as it arrives,
//  once; a keyed slot replaced in place only when its words change; a progress card once it
//  finishes, with its outcome; a problem toast at high priority. Nothing is said as a toast
//  expires or a card goes. The hosted half (one push, one post) is ToastCardTests'. F17: a
//  routine announcement is queued behind what VoiceOver is saying (low priority), so a
//  burst keeps every one; only a problem interrupts (high).
//

import SwiftUI
import Testing
import MachmanUI

struct ToastAnnouncementTests {
	private static func toast(
		_ message: String, key: String? = nil, tint: Color? = nil
	) -> MachmanToast {
		MachmanToast(symbol: MachmanSymbols.warning, message: message, tint: tint, key: key)
	}

	private static func card(_ id: String, finished: Bool, phase: String) -> ProgressCardModel {
		ProgressCardModel(
			id: id, title: "Debian — Copy", symbol: "", phase: phase, finished: finished)
	}

	@Test("H56: a toast is said once, a moved slot with new words, a finished card its outcome")
	func whatTheCornerSays() {
		let removed = Self.toast("Removed console port")
		#expect(ToastStack.announcements(from: [], to: [removed]) == [
			ToastAnnouncement(text: "Removed console port", urgent: false),
		])
		// Still showing, or gone: nothing new to say.
		#expect(ToastStack.announcements(from: [removed], to: [removed]).isEmpty)
		#expect(ToastStack.announcements(from: [removed], to: []).isEmpty)

		// A slot that moves (waiting → ready) says its new words, not the same ones twice.
		let waiting = Self.toast("Debian: waiting for SSH…", key: "ssh.Debian")
		let again = Self.toast("Debian: waiting for SSH…", key: "ssh.Debian")
		let ready = Self.toast("Debian: SSH ready", key: "ssh.Debian")
		#expect(ToastStack.announcements(from: [waiting], to: [again]).isEmpty)
		#expect(ToastStack.announcements(from: [again], to: [ready]).map(\.text)
			== ["Debian: SSH ready"])

		// A card says nothing while it runs, its outcome once it finishes, then nothing.
		let running = Self.card("op", finished: false, phase: "13 GB of 32 GB")
		let done = Self.card("op", finished: true, phase: "Done")
		#expect(ToastStack.announcements(from: [], to: [running]).isEmpty)
		#expect(ToastStack.announcements(from: [running], to: [done]) == [
			ToastAnnouncement(text: "Debian — Copy: Done", urgent: false),
		])
		#expect(ToastStack.announcements(from: [done], to: [done]).isEmpty)
		#expect(ToastStack.announcements(from: [done], to: []).isEmpty)
		// One that arrives already finished (a failure on the first event) says it too.
		let failed = Self.card("import", finished: true, phase: "Not a disk image")
		#expect(ToastStack.announcements(from: [], to: [failed]).map(\.text)
			== ["Debian — Copy: Not a disk image"])
	}

	@Test("H56: a problem toast is announced at high priority")
	func aProblemInterrupts() {
		let problem = Self.toast("Debian hit an error", tint: MachmanColors.warning)
		let confirmation = Self.toast("Renamed to “dev”", tint: MachmanColors.connected)
		#expect(problem.isProblem)
		#expect(!confirmation.isProblem)
		#expect(ToastStack.announcements(from: [], to: [problem, confirmation]) == [
			ToastAnnouncement(text: "Debian hit an error", urgent: true),
			ToastAnnouncement(text: "Renamed to “dev”", urgent: false),
		])
	}

	// .default would interrupt the current speech and be cut off by the next post.
	@Test("F17: a routine announcement waits its turn, a problem interrupts")
	func routineSpeechIsQueued() {
		let routine = ToastAnnouncer.speech(
			for: ToastAnnouncement(text: "Removed console port", urgent: false))
		let problem = ToastAnnouncer.speech(
			for: ToastAnnouncement(text: "Debian hit an error", urgent: true))
		#expect(routine.accessibilitySpeechAnnouncementPriority == .low)
		#expect(problem.accessibilitySpeechAnnouncementPriority == .high)
		#expect(String(routine.characters) == "Removed console port")
	}
}
