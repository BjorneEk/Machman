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
	case run  = "play.circle"
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

class VMListViewModel: ObservableObject {
	@Published var		vmMap: [String: VirtualMachine] = [:]
	@State var			log: [VirtualMachineLog] = []

	@Published private var	previewImage: NSImage?
	@State private var		timer: Timer?
	@Published private var	isFocused = true
	@State private var		hUpdatePreview: Double = 4.0
	@Published var				selected: VirtualMachine? = nil
	@Published var				vmName: String = ""


	init () {
		let folderURL = URL(fileURLWithPath: machmanVMDir)
		let fileManager = FileManager.default

		do {
			let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])

			let vmList: [VirtualMachine] = try contents.filter { url in
				let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
				return resourceValues.isDirectory ?? false
			}
			.map { try? VirtualMachine(config: VMConfig(name: String($0.lastPathComponent))) }
			.compactMap { $0 }
			for (_, contf) in vmList.enumerated() {
				vmMap["\(contf.config.name)"] = contf
			}
		} catch {
			log(error: "Error reading machines: \(error)")
		}
	}

	func log(_ e: VirtualMachineLog) {
		self.log.append(e)
	}

	func log(error: String) {
		self.log.append(.error(error))
	}

	func log(message: String) {
		self.log.append(.message(message))
	}

	func log(warning: String) {
		self.log.append(.warning(warning))
	}

	func startTimer() {
		//stopTimer()
		DispatchQueue.main.async {
			if self.timer != nil { return }
			if let vm = self.selected {
				if vm.config.state == .running && self.timer?.isValid ?? true {
					print("timer started: \(Foundation.Date())")
					self.timer = Timer.scheduledTimer(withTimeInterval: self.hUpdatePreview, repeats: true) { [weak self] _ in
						if self?.isFocused ?? false {
							self?.updatePreview()
						} //else {
						//self.stopTimer()
						//}
					}
				}
			}
		}
	}
	func preview() -> NSImage? {
		return (self.previewImage ?? self.selected?.previewImage)
	}
	func stopTimer() {
		DispatchQueue.main.async {
			print("timer stopped: \(Foundation.Date())")
			self.timer?.invalidate()
			self.timer = nil
		}
	}

	private func updatePreview() {
		DispatchQueue.main.async {
			if let vm = self.selected {
				if vm.config.state == .running && self.isFocused {
					print("updated preview: \(self.selected?.config.name ?? "unkonwn") (\(Foundation.Date()))")
					vm.captureWindowImage { image in
						self.previewImage = image
						vm.updatePreview(img: image)
					}
				}
			}
		}
	}

	func isLoading() -> Bool {
		if let vm = self.selected {
			return vm.config.state == .running && self.previewImage == nil
		}
		return false
	}

	func onFocusEvent(focused: Bool) {

		if let vm = self.selected {
			let change = focused != self.isFocused
			self.isFocused = focused
			if self.isFocused && vm.config.state == .running {
				if change {
					print("from onFocusEvent")
					self.updatePreview()
				}
				self.startTimer()
			} else {
				self.stopTimer()
			}
		}
	}

	func vmList() -> [VirtualMachine] {
		return vmMap.map {
			$0.value
		}.sorted(by: {
			$0.config.lastRan ?? .distantPast > $1.config.lastRan ?? .distantPast
		})
	}

	func runBtnLbl(c: VMConfig) -> RunBtnState {
		return RunBtnState.fromVMState(s: vmMap[c.name]?.config.state ?? VMState.stopped)
	}

	func forceUpdate() {
		self.objectWillChange.send()
	}

	func hasVM(_ name: String) -> Bool {
		return vmMap[name] != nil
	}

	func select(vm: VirtualMachine?) {
		self.selected = vm
		self.vmName = vm?.config.name ?? ""
		self.previewImage = vm?.previewImage
		//stopTimer()
	}

	func addVM(vmConfig: VMConfig) {
		vmMap[vmConfig.name] = VirtualMachine(config: vmConfig)
	}
	func onStopped() {

	}
	private func _run(c: VMConfig, iso: URL? = nil) {
		stopTimer()
		let t = vmMap[c.name]
		if let vm = t {
			switch vm.config.state {
				case .stopped:
					do {
						try vm.startVMWindow(viewModel: self, isoPath: iso)
					} catch {
						log(error: "(\(vm.config.name)) \(error)")
						try? vm.config.stop()
					}
				case .running:
					vm.stopVM()
			}
		} else {
			log(error: "no VM named \(c.name)")
		}
		forceUpdate()
	}

	func run(c: VMConfig) {
		_run(c: c)
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

	func delete(vm: VirtualMachine) {
		stopTimer()
		if !VMListViewModel.confirmDialog(
			message: "Delete \(vm.config.name)?",
			informativeText: "Are you sure you want to delete \(vm.config.name)? This action cannot be undone.") {
			return
		}

		vmMap[vm.config.name] = nil

		do {
			try VMConfig.deleteVMDirectory(name: vm.config.name)
		} catch {
			log(error: "Failed to delete \(vm.config.name)")
		}
		self.selected = nil
		forceUpdate()
	}
	func addNewVM() -> VirtualMachine {
		var name = "new-VM"
		var nbr: Int = 1
		while vmMap["\(name)\(nbr)"] != nil {
			nbr += 1
		}
		name = "\(name)\(nbr)"
		try! VMConfig.createNewVMDirectory(name: name)
		let new = VirtualMachine(config: try! VMConfig(
			name: name,
			memorySize: 4,
			cpuCount: VMConfig.computeMaxCPUCount()))
		vmMap[name] = new
		return new
	}
	func build(c: VMConfig) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.diskImage]
		panel.begin { response in
			if response == .OK, let selectedURL = panel.url {
				self.log(message: "Selected file: \(selectedURL.path)")
				self.log(message:"Building \(c.name)")
				self._run(c: c, iso: selectedURL)
			} else {
				self.log(error: "Build Failed for: \(c.name), No ISO file selected.")
			}
		}
	}
}
