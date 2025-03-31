//
//  VMListViewModel.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-29.
//

import Foundation
import AppKit
import SwiftUI

enum RunBtnState: String {
	//case run = "play.fill"
	case run  = "power"
	case stop = "stop.circle"

	static func fromVMState(s: VMState) -> RunBtnState {
		switch s {
		case .running:
			return .stop
		default:
			return .run
		}
	}
	func color() -> Color {
		switch self {
		case .run:
			return .green
		case .stop:
			return .red
		}
	}
	func running() -> Bool {
		switch self {
		case .run:
			return false
		case .stop:
			return true
		}
	}
}

let runBtnStateInit: RunBtnState = .run

class VMListViewModel: ObservableObject {
	@Published var vmMap: [String: (config: VMConfig, controller: VMController?)] = [:]
	init () {
		let folderURL = URL(fileURLWithPath: machmanVMDir)
		let fileManager = FileManager.default

		do {
			let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])

			let vmList: [(config: VMConfig, controller: VMController?)] = try contents.filter { url in
				let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
				return resourceValues.isDirectory ?? false
			}.map { try (config: VMConfig(name: String($0.lastPathComponent)), controller: nil) }
			for (_, contf) in vmList.enumerated() {
				vmMap["\(contf.config.name)"] = contf
			}
		} catch {
			fatalError("Error reading machines: \(error)")
		}
	}

	func vmList() -> [(config: VMConfig, state: RunBtnState)] {
		return vmMap.map {(
			config: $0.value.config,
			state: RunBtnState.fromVMState(s: $0.value.controller?.vmState() ?? .stopped)
		)}.sorted(by: {
			$0.config.lastRan ?? .distantPast > $1.config.lastRan ?? .distantPast
		})
	}

	func runBtnLbl(c: VMConfig) -> RunBtnState {
		return RunBtnState.fromVMState(s: vmMap[c.name]?.controller?.vmState() ?? VMState.stopped)
	}

	func forceUpdate() {
		self.objectWillChange.send()
	}

	func hasVM(_ name: String) -> Bool {
		return vmMap[name] != nil
	}

	func addVM(vmConfig: VMConfig) {
		vmMap[vmConfig.name] = (config: vmConfig, controller: nil)
	}

	private func _run(c: VMConfig, iso: String? = nil) {
		let t = vmMap[c.name]
		if let controller = t?.controller {
			switch controller.vmState() {
				case .stopped:
					vmMap[c.name] = (config: c, controller: controller)
					controller.startVMWindow(viewModel: self)
				case .running:
					controller.stopVM()
			}
		} else {
			let controller = VMController(c, iso: iso)
			vmMap[c.name] = (config: c, controller: controller)
			controller.startVMWindow(viewModel: self)
		}
		forceUpdate()
	}
	func run(c: VMConfig) {
		_run(c: c)
	}

	func addNew() {
		
	}

	static func confirmDialog(message: String, informativeText: String) -> Bool {
		let alert = NSAlert()
		alert.messageText = message
		alert.informativeText = informativeText
		alert.alertStyle = .warning
		alert.addButton(withTitle: "OK")
		alert.addButton(withTitle: "Cancel")

		let response = alert.runModal()
		return response == .alertFirstButtonReturn
	}

	func delete(c: VMConfig) {

		if !VMListViewModel.confirmDialog(
			message: "Delete \(c.name)?",
			informativeText: "Are you sure you want to delete \(c.name)? This action cannot be undone.") {
			return
		}

		vmMap[c.name] = nil

		do {
			try VMConfig.deleteVMDirectory(name: c.name)
		} catch {
			let alert = NSAlert()
			alert.messageText = "Delete failed"
			alert.informativeText = "Failed to delete \(c.name)"
			alert.alertStyle = .warning
			alert.addButton(withTitle: "OK")
			alert.runModal()
		}
		forceUpdate()
	}

	func build(c: VMConfig) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.diskImage]
		panel.begin { response in
			if response == .OK, let selectedURL = panel.url {
				print("Selected file: \(selectedURL.path)")
				print("Building \(c.name)")
				self._run(c: c, iso: selectedURL.path)
			} else {
				let alert = NSAlert()
				alert.messageText = "Build Failed"
				alert.informativeText = "No ISO file selected."
				alert.alertStyle = .warning
				alert.addButton(withTitle: "OK")
				alert.runModal()
			}
		}
	}
}
