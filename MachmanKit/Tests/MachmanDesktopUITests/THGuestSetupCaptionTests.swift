//
//  THGuestSetupCaptionTests.swift
//  MachmanDesktopUITests
//
//  The Guest Setup inspector's BSD commands as a person reads them (X9): on an EFI VM whose
//  share does not automount, the "FreeBSD / OpenBSD" group — collapsed until pressed — says
//  to mount the share over sshfs first, then shows the run line. Its L3 half (the lines run
//  in a FreeBSD guest) is r3-th's S9 in MachmanLabTests.
//

import AppKit
import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: the inspector hosted offscreen, read through in-process accessibility.
@MainActor
struct THGuestSetupCaptionTests {
	static let caption =
		"No virtiofs driver, so mount the share over sshfs first (see the Setup Guide), then run:"

	@Test("W4-5: the FreeBSD / OpenBSD group's caption reads the sshfs-first sentence")
	func bsdGroupCaption() async throws {
		// A failed last run serves the installer again, so the inspector shows its commands;
		// the sample's report has no share automount.
		let sample = Samples.failedSetupRun("Debian")
		#expect(sample.boot.mode == .efi)
		#expect(!(sample.setup?.automounts ?? []).contains { $0.kind == MountKind.virtiofs })
		let h = await UIHarness.make([sample], select: sample.name)
		let inspector = GuestSetupInspector(viewModel: h.viewModel, vm: h.vm(sample.name))
		let (collapsed, expanded, pressed) = try await OffscreenHost.withHost(
			inspector, width: 420, height: 1100
		) { hosted -> (AXSnapshot, AXSnapshot, Bool) in
			let before = hosted.snapshot()
			let pressed = Self.press(label: "FreeBSD / OpenBSD", under: hosted.host)
			await hosted.settle()
			return (before, hosted.snapshot(), pressed)
		}
		let run = GuestSetupCommands.run(.bsd, shareMounted: true)
		#expect(run == "doas " + GuestSetupInstallerInfo.runCommand())
		#expect(collapsed.find(text: Self.caption) == nil, "the group starts collapsed")
		try #require(pressed, "the FreeBSD / OpenBSD group took no press")
		let texts = expanded.all.compactMap(\.text)
		let at = try #require(texts.firstIndex(of: Self.caption), "\(expanded.dump())")
		#expect(texts[(at + 1)...].first { $0.contains("install.sh") } == run)
	}

	// Presses the live element labelled `label` (SwiftUI's nodes answer the NSAccessibility
	// getters without conforming: every selector is checked before it is sent).
	private static func press(label: String, under root: NSObject) -> Bool {
		var queue: [NSObject] = [root]
		var seen = 0
		while !queue.isEmpty, seen < AXSnapshot.maxNodes {
			let node = queue.removeFirst()
			seen += 1
			let name = ["accessibilityLabel", "accessibilityTitle"].compactMap { getter in
				node.responds(to: NSSelectorFromString(getter))
					? node.value(forKey: getter) as? String : nil
			}
			let press = NSSelectorFromString("accessibilityPerformPress")
			if name.contains(label), node.responds(to: press) {
				_ = node.perform(press)
				return true
			}
			if node.responds(to: NSSelectorFromString("accessibilityChildren")),
				let kids = node.value(forKey: "accessibilityChildren") as? [Any] {
				queue += kids.compactMap { $0 as? NSObject }
			}
		}
		return false
	}
}
