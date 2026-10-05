//
//  AXSnapshot.swift
//  MachmanTestSupport
//
//  The accessibility tree of a hosted view (OffscreenHost) as a plain value: what VoiceOver
//  would read — role, label, value, help, enabled, selected, named actions, frame — captured
//  in-process from our own view objects. Never through the AX server (AXUIElement): no TCC
//  prompt, nothing outside the test process. Read-only: it never presses or performs an
//  action (an action can write the pasteboard, reveal in Finder or start a VM — prove those
//  on the view model instead).
//
//  What reads (spike, macOS 26, $RF/scratch/r3-ta/ax-spike.md): SwiftUI builds no
//  accessibility children until assistive tech is on, so OffscreenHost.prepare() sets
//  AXEnhancedUserInterface on the test process's own NSApp. Then Button (label, help,
//  enabled), Toggle (value "1"/"0"), Text (value), traits (.isSelected), named actions,
//  ControlGroup segments, Form sections, toolbar items (chrome .window) and List rows read;
//  frames too. SwiftUI's nodes answer the modern getters but don't formally conform to
//  NSAccessibility, and AppKit's table rows answer only the informal attribute API — both
//  are read through `responds(to:)`-guarded calls (an unknown selector would kill the run).
//  accessibilityTitle is absent on SwiftUI nodes; image-only buttons carry their symbol name
//  as identifier.
//
//  Menus: a context menu's content never reaches the tree until it opens, so a test lays
//  the content out as views instead (MachmanDesktopUITests' TreeMenuProbe): each Button
//  reads as an AXButton with its title, enabled state and help.
//

import AppKit

public struct AXSnapshot: Equatable, Sendable {
	public var role: String
	public var subrole: String?
	public var label: String?
	public var title: String?
	public var value: String?   // stringified: a toggle's 1/0, a text's string
	public var help: String?
	public var identifier: String?
	public var isElement: Bool
	public var isEnabled: Bool
	public var isSelected: Bool
	public var actions: [String]   // custom action names (.accessibilityAction(named:))
	public var frame: CGRect?      // host coordinates, top-left origin
	public var children: [AXSnapshot]

	public init(
		role: String, subrole: String? = nil, label: String? = nil, title: String? = nil,
		value: String? = nil, help: String? = nil, identifier: String? = nil,
		isElement: Bool = true, isEnabled: Bool = true, isSelected: Bool = false,
		actions: [String] = [], frame: CGRect? = nil, children: [AXSnapshot] = []
	) {
		self.role = role
		self.subrole = subrole
		self.label = label
		self.title = title
		self.value = value
		self.help = help
		self.identifier = identifier
		self.isElement = isElement
		self.isEnabled = isEnabled
		self.isSelected = isSelected
		self.actions = actions
		self.frame = frame
		self.children = children
	}

	// What a person hears first: the label, else the title, else the value.
	public var text: String? { label ?? title ?? value }

	// MARK: - Finding

	// This node and every descendant, depth first.
	public var all: [AXSnapshot] {
		[self] + children.flatMap(\.all)
	}

	public func findAll(where match: (AXSnapshot) -> Bool) -> [AXSnapshot] {
		all.filter(match)
	}

	public func find(label: String) -> AXSnapshot? {
		all.first { $0.label == label }
	}

	public func find(text: String) -> AXSnapshot? {
		all.first { $0.text == text }
	}

	public func find(role: String, text: String) -> AXSnapshot? {
		all.first { $0.role == role && $0.text == text }
	}

	// MARK: - Pruning and dumps

	// The tree a person navigates: a non-element without text, help or actions gives its
	// place to its children, and a group left with nothing to say or hold goes.
	public func pruned() -> AXSnapshot {
		var root = self
		root.children = children.flatMap { $0.prunedNodes() }
		return root
	}

	private func prunedNodes() -> [AXSnapshot] {
		var node = self
		node.children = children.flatMap { $0.prunedNodes() }
		if node.saysNothing {
			if !node.isElement { return node.children }
			if node.role == "AXGroup", node.children.isEmpty { return [] }
		}
		return [node]
	}

	private var saysNothing: Bool {
		text == nil && help == nil && actions.isEmpty
	}

	// The pruned tree as stable text for goldens, two spaces per level: `AXButton "Shut Down"
	// help="…" value="…" id="…" [disabled] [selected] actions=[Close Tab]`. Nil fields are
	// left out, and so is a silent container's [disabled]; frames (rounded, `@x,y wxh`) only on
	// request.
	public func dump(frames: Bool = false) -> String {
		var lines: [String] = []
		pruned().appendLines(to: &lines, depth: 0, frames: frames)
		return lines.joined(separator: "\n")
	}

	private func appendLines(to lines: inout [String], depth: Int, frames: Bool) {
		var line = String(repeating: "  ", count: depth) + role
		if let subrole { line += "/\(subrole)" }
		if let text { line += " " + Self.quoted(text) }
		if let label, label != text { line += " label=" + Self.quoted(label) }
		if let title, title != text { line += " title=" + Self.quoted(title) }
		if let value, value != text { line += " value=" + Self.quoted(value) }
		if let help { line += " help=" + Self.quoted(help) }
		if let identifier { line += " id=" + Self.quoted(identifier) }
		// AppKit reports its containers (hosting views, split views, toolbars) as not enabled
		// as a matter of course; enabled matters on what a person reads or acts on.
		if !isEnabled, !saysNothing { line += " [disabled]" }
		if isSelected { line += " [selected]" }
		if !actions.isEmpty { line += " actions=[\(actions.joined(separator: ", "))]" }
		if frames, let frame {
			line += " @\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded()))"
				+ " \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
		}
		lines.append(line)
		for child in children {
			child.appendLines(to: &lines, depth: depth + 1, frames: frames)
		}
	}

	private static func quoted(_ s: String) -> String {
		let escaped = s
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
			.replacingOccurrences(of: "\n", with: "\\n")
		return "\"\(escaped)\""
	}
}

// MARK: - Capture

extension AXSnapshot {
	public static let maxDepth = 64
	public static let maxNodes = 5000

	// The tree under `root` (a hosting view, or the window for chrome .window), frames in
	// `host`'s coordinates. Accessibility must be on (OffscreenHost.prepare()).
	@MainActor
	public static func capture(_ root: NSObject, in host: NSView) -> AXSnapshot {
		var budget = maxNodes
		return AXReader(host: host).read(root, depth: 0, budget: &budget)
			?? AXSnapshot(role: "AXUnknown", isElement: false)
	}
}

// Reads one object, whichever of the two in-process APIs it answers.
@MainActor
private struct AXReader {
	let host: NSView

	func read(_ any: Any, depth: Int, budget: inout Int) -> AXSnapshot? {
		guard budget > 0, let object = any as? NSObject else { return nil }
		budget -= 1
		var node: AXSnapshot
		let kids: [Any]
		if object.responds(to: NSSelectorFromString("accessibilityRole")) {
			(node, kids) = modern(object)
		} else if object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) {
			(node, kids) = legacy(object)
		} else {
			return AXSnapshot(role: "AXUnknown", isElement: false)
		}
		if depth < AXSnapshot.maxDepth {
			node.children = kids.compactMap { read($0, depth: depth + 1, budget: &budget) }
		}
		return node
	}

	// The NSAccessibility getters, through KVC: SwiftUI's nodes answer them without formally
	// conforming, and every getter is checked first.
	private func modern(_ o: NSObject) -> (AXSnapshot, [Any]) {
		func get(_ getter: String, key: String? = nil) -> Any? {
			guard o.responds(to: NSSelectorFromString(getter)) else { return nil }
			return o.value(forKey: key ?? getter)
		}
		func flag(_ getter: String, _ key: String, default fallback: Bool) -> Bool {
			(get(getter, key: key) as? NSNumber)?.boolValue ?? fallback
		}
		let actions = (get("accessibilityCustomActions") as? [NSAccessibilityCustomAction])?
			.map(\.name) ?? []
		let screen = (get("accessibilityFrame") as? NSValue)?.rectValue
		let node = AXSnapshot(
			role: Self.string(get("accessibilityRole")) ?? "AXUnknown",
			subrole: Self.string(get("accessibilitySubrole")),
			label: Self.string(get("accessibilityLabel")),
			title: Self.string(get("accessibilityTitle")),
			value: Self.string(get("accessibilityValue")),
			help: Self.string(get("accessibilityHelp")),
			identifier: Self.string(get("accessibilityIdentifier")),
			isElement: flag("isAccessibilityElement", "accessibilityElement", default: true),
			isEnabled: flag("isAccessibilityEnabled", "accessibilityEnabled", default: true),
			isSelected: flag("isAccessibilitySelected", "accessibilitySelected", default: false),
			actions: actions,
			frame: screen.flatMap(toHost))
		return (node, get("accessibilityChildren") as? [Any] ?? [])
	}

	// The informal attribute API (AppKit's table rows and cells answer only this).
	private func legacy(_ o: NSObject) -> (AXSnapshot, [Any]) {
		func attribute(_ name: String) -> Any? {
			o.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: name)?
				.takeUnretainedValue()
		}
		var frame: CGRect?
		if let position = (attribute("AXPosition") as? NSValue)?.pointValue,
			let size = (attribute("AXSize") as? NSValue)?.sizeValue {
			frame = toHost(CGRect(origin: position, size: size))
		}
		let node = AXSnapshot(
			role: Self.string(attribute("AXRole")) ?? "AXUnknown",
			subrole: Self.string(attribute("AXSubrole")),
			label: Self.string(attribute("AXDescription")),
			title: Self.string(attribute("AXTitle")),
			value: Self.string(attribute("AXValue")),
			help: Self.string(attribute("AXHelp")),
			identifier: Self.string(attribute("AXIdentifier")),
			isElement: true,
			isEnabled: (attribute("AXEnabled") as? NSNumber)?.boolValue ?? true,
			isSelected: (attribute("AXSelected") as? NSNumber)?.boolValue ?? false,
			frame: frame)
		return (node, attribute("AXChildren") as? [Any] ?? [])
	}

	// Screen coordinates (bottom-left origin) → the host's (a hosting view is flipped).
	private func toHost(_ screen: CGRect) -> CGRect? {
		guard let window = host.window else { return nil }
		return host.convert(window.convertFromScreen(screen), from: nil)
	}

	// Empty strings read as nothing (SwiftUI reports "" for an unset identifier).
	private static func string(_ any: Any?) -> String? {
		guard let any else { return nil }
		switch any {
		case let s as String: return s.isEmpty ? nil : s
		case let a as NSAttributedString: return a.string.isEmpty ? nil : a.string
		case let n as NSNumber: return n.stringValue
		default: return "\(any)"
		}
	}
}

extension HostedView {
	// The hosted view's tree; for chrome .window the window's (toolbar included).
	public func snapshot() -> AXSnapshot {
		AXSnapshot.capture(chrome == .window ? window : host, in: host)
	}
}
