//
//  FieldTyping.swift
//  MachmanDesktopUITests
//
//  Text typed into a hosted SwiftUI TextField the way AppKit reports typing: the backing
//  NSTextField's string changes and its delegate hears controlTextDidChange, which is how
//  SwiftUI's binding learns of it. Never a first responder, a key window or an event: the
//  window stays unordered (OffscreenHost), so nothing reaches the screen or the keyboard.
//

import AppKit
import MachmanTestSupport

@MainActor
enum FieldTyping {
	// Types `text` into the text field whose frame (host coordinates, as AXSnapshot reads
	// them) holds `frame`'s centre, then settles. False when no field is there.
	@discardableResult
	static func type(_ text: String, intoFieldAt frame: CGRect, in hosted: HostedView) async
		-> Bool {
		let centre = CGPoint(x: frame.midX, y: frame.midY)
		guard let field = textField(at: centre, in: hosted.host) else { return false }
		field.stringValue = text
		let change = Notification(name: NSControl.textDidChangeNotification, object: field)
		field.delegate?.controlTextDidChange?(change)
		await hosted.settle()
		return true
	}

	// The innermost text field under `point` (host coordinates).
	static func textField(at point: CGPoint, in host: NSView) -> NSTextField? {
		var found: NSTextField?
		func walk(_ view: NSView) {
			if let field = view as? NSTextField, field.isEditable,
				host.convert(field.bounds, from: field).contains(point) {
				found = field
			}
			view.subviews.forEach(walk)
		}
		walk(host)
		return found
	}
}
