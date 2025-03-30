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
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

	var body: some Scene {
		WindowGroup {
			VMListView()
		}
	}
}
class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}
