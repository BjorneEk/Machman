//
//  MachmanApp.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-27.
//

import SwiftUI

let _vmPath: String = "/Users/gustaf/dev/2025/Machman-files"
@main
struct MachmanApp: App {
	let isoPath: String = "/Users/gustaf/Downloads/debian-12.9.0-arm64-netinst.iso"
	let vmPath: String = "/Users/gustaf/dev/2025/Machman-files"
	let vmController = VMController(
		vmPath: _vmPath,
		cpuCount: 8,
		ramSize: 16 * 1024 * 1024 * 1024
	)
	var body: some Scene {
		WindowGroup {
			VMView(vmController: vmController)
		}
	}
}
