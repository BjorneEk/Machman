//
//  VMHostLocator.swift
//  MachmanCore
//
//  The single answer to "where is the vmhost app?". Used by the spawner and, in phase 5, by
//  the LaunchAgent plist writer — both must point at the same binary. Resolution order:
//    1. embedded beside this daemon in the outer bundle:
//       <outer>.app/Contents/Library/MachmanVMHost.app
//       (the daemon lives at <outer>.app/Contents/Library/LoginItems/Machmand.app → ../../)
//    2. sibling build product (Machmand scheme run from DerivedData):
//       <dir of Machmand.app>/MachmanVMHost.app
//

import Foundation

struct VMHostLocation {
	let appURL: URL          // what NSWorkspace launches
	let executableURL: URL   // what LaunchAgent plists point at
}

enum VMHostLocator {
	static let bundleName = "MachmanVMHost.app"

	static func locate(from bundleURL: URL = Bundle.main.bundleURL) -> VMHostLocation? {
		let embedded = bundleURL
			.deletingLastPathComponent()   // …/Contents/Library/LoginItems
			.deletingLastPathComponent()   // …/Contents/Library
			.appendingPathComponent(bundleName)
		let sibling = bundleURL
			.deletingLastPathComponent()
			.appendingPathComponent(bundleName)
		for app in [embedded, sibling] {
			let executable = app.appendingPathComponent("Contents/MacOS/MachmanVMHost")
			if FileManager.default.fileExists(atPath: executable.path) {
				return VMHostLocation(appURL: app, executableURL: executable)
			}
		}
		return nil
	}
}
