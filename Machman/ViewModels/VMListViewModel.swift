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

	@Published private var	isFocused = true
	private let				hUpdatePreview: Double = 4
	@Published var				selected: VirtualMachine? = nil
	@Published var				vmName: String = ""

	private lazy var previewUpdateManager: PeriodicTaskManager<NSImage?> = {
		return PeriodicTaskManager(
			interval: hUpdatePreview,
			task: self.getUpdatedPreviewImage,
			update: self.setUpdatedPreviewImage
		)
	}()

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
		self.previewUpdateManager.debug = true
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

	private func getUpdatedPreviewImage() -> NSImage? {
		guard let vm = self.selected else { return nil }
		let semaphore = DispatchSemaphore(value: 0)
		var result: NSImage? = nil

		vm.captureWindowImage { image in
			result = image
			semaphore.signal()
		}

		semaphore.wait()
		return result
	}

	private func setUpdatedPreviewImage(img: NSImage?) {
		guard let vm = self.selected else { return }
		guard let img = img else { return }
		self.previewImage = img
		vm.updatePreview(img: img)
	}

	func preview() -> NSImage? {
		return (self.previewImage ?? self.selected?.previewImage)
	}

	func isLoading() -> Bool {
		guard let vm = self.selected else { return false }
		return vm.config.state == .running && self.previewImage == nil
	}

	func onFocusEvent(focused: Bool) {
		print("focus envent, focused: \(focused)")
		guard let vm = self.selected else { return }
		self.isFocused = focused
		guard self.isFocused && vm.config.state == .running else {
			self.previewUpdateManager.stop()
			return
		}
		self.previewUpdateManager.start()
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
		self.previewUpdateManager.stop()
		self.selected = vm
		self.vmName = vm?.config.name ?? ""
		self.previewImage = vm?.previewImage
	}

	func addVM(vmConfig: VMConfig) {
		vmMap[vmConfig.name] = VirtualMachine(config: vmConfig)
	}
	func onStopped() {

	}
	private func _run(c: VMConfig, iso: URL? = nil) {
		self.previewUpdateManager.stop()

		guard let vm = vmMap[c.name] else {
			log(error: "no VM named \(c.name)")
			return
		}
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
		self.previewUpdateManager.stop()
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
}
