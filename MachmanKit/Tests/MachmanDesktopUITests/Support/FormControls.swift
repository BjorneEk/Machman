//
//  FormControls.swift
//  MachmanDesktopUITests
//
//  A grouped Form reads a labelled control (a Toggle, a Picker) as two siblings in its row's
//  group: the label's static text, then the control with its value but no label of its own.
//  `control(labelled:)` finds the control by the label a person sees beside it.
//

import MachmanTestSupport

extension AXSnapshot {
	// The first control after the static text `title`, among that text's siblings; searched
	// depth first.
	func control(labelled title: String) -> AXSnapshot? {
		if let label = children.firstIndex(where: {
			$0.role == "AXStaticText" && $0.text == title
		}), let next = children[(label + 1)...].first(where: { $0.role != "AXStaticText" }) {
			return next
		}
		for child in children {
			if let found = child.control(labelled: title) { return found }
		}
		return nil
	}
}
