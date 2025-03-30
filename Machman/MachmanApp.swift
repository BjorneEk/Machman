//
//  MachmanApp.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-27.
//

import SwiftUI
import Cocoa

let machmanVMDir: String = NSHomeDirectory() + "/.machman"


@main
struct MachmanApp: App {

	/*let vmConfig = try! VMConfig(
		name: "debian",
		memorySize: 16 * 1024 * 1024 * 1024,
		cpuCount: 8

	)*/

	var body: some Scene {
		WindowGroup {
			VMListView()
			//VMView(vmController: VMController(vmConfig))
		}
	}
}
