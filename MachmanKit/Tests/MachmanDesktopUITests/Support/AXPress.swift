//
//  AXPress.swift
//  MachmanDesktopUITests
//
//  Presses a hosted view's element the way VoiceOver does (accessibilityPerformPress), for the
//  few tests that must see what a button does. SwiftUI's nodes answer the NSAccessibility
//  getters without conforming to the protocol, so every selector is checked before it is sent.
//  Never a key window or an event: the host stays unordered (OffscreenHost).
//

import AppKit
import MachmanTestSupport

@MainActor
enum AXPress {
	// Presses the first live element (breadth first under `root`) whose label or title is
	// `label`. False when there is none.
	static func press(label: String, under root: NSObject) -> Bool {
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
