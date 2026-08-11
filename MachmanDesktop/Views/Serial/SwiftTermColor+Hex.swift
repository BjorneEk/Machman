//
//  SwiftTermColor+Hex.swift
//  MachmanDesktop
//
//  Bridge a MachmanUI "#rrggbb" colour string to a SwiftTerm.Color. Lives in the app target
//  because MachmanUI must never link SwiftTerm; the hex parsing itself is shared from MachmanUI.
//

import SwiftTerm
import MachmanUI

extension SwiftTerm.Color {
	// SwiftTerm.Color is 16-bit-per-channel; its red8/green8/blue8 initializer scales 8-bit input.
	static func from(hexColor: String) -> SwiftTerm.Color? {
		guard let c = parseHexColor(hexColor) else { return nil }
		return SwiftTerm.Color(red8: UInt16(c.r), green8: UInt16(c.g), blue8: UInt16(c.b))
	}
}
