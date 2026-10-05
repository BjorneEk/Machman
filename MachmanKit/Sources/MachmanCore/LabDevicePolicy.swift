//
//  LabDevicePolicy.swift
//  MachmanCore
//
//  The devices a test-suite VM starts without, so a lab run never reaches the host: audio
//  input and output always (a microphone permission prompt, sound), the USB keyboard,
//  pointer and Mac trackpad unless the lab opts in with MACHMAN_LAB_DEVICES=hid, and the
//  spice agent's clipboard sharing unless it opts in with `clipboard` (a guest's copy would
//  change the Mac's pasteboard). The spice port itself stays, so the device topology is the
//  one a person's VM has. Outside test mode there is no policy.
//

import Foundation
import MachmanAPI

struct LabDevicePolicy: Equatable {
	let optIns: Set<String>

	static func current(lab: LabEnvironment?) -> LabDevicePolicy? {
		lab.map { LabDevicePolicy(optIns: $0.deviceOptIns) }
	}

	static let hidKinds: Set<DeviceKind> = [.keyboard, .pointer, .trackpad]

	func drops(_ kind: DeviceKind) -> Bool {
		switch kind {
		case .audioInput, .audioOutput: return true
		default: return Self.hidKinds.contains(kind) && !optIns.contains("hid")
		}
	}

	var sharesClipboard: Bool { optIns.contains("clipboard") }

	// The resolved devices minus the dropped ones, which come back in a stable order.
	func apply(
		_ attach: [DeviceKind: GuestDevice]
	) -> (kept: [DeviceKind: GuestDevice], dropped: [DeviceKind]) {
		let dropped = attach.keys.filter(drops).sorted { $0.rawValue < $1.rawValue }
		return (attach.filter { !drops($0.key) }, dropped)
	}

	// "audio input, keyboard": the log's words for dropped kinds.
	static func describe(_ kinds: [DeviceKind]) -> String {
		kinds.map { kind in
			kind.rawValue.reduce(into: "") { words, character in
				if character.isUppercase { words += " " }
				words += character.lowercased()
			}
		}.joined(separator: ", ")
	}
}
