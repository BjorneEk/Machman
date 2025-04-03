//
//  PreviewViewModel.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import Foundation
import SwiftUI

class PreviewViewModel: ObservableObject {
	@State private var vm: VirtualMachine
	@Published private var previewImage: NSImage?

	@State private var timer: Timer?
	@Published private var isFocused = true
	@State private var hUpdatePreview: Double

	init(vm: VirtualMachine, hUpdatePreview: Double = 10.0) {
		self.vm = vm
		self.previewImage = vm.previewImage
		self.hUpdatePreview = hUpdatePreview
	}
	func startTimer() {
		stopTimer()
		timer = Timer.scheduledTimer(withTimeInterval: hUpdatePreview, repeats: true) { _ in
			if self.isFocused {
				print("isfoucsed: \(self.isFocused)")
				self.updatePreview()
			} else {
				self.stopTimer()
			}
		}
	}
	func preview() -> NSImage? {
		return (self.previewImage ?? self.vm.previewImage)
	}
	func stopTimer() {
		timer?.invalidate()
		timer = nil
	}

	private func updatePreview() {
		//DispatchQueue.main.async {
			if self.vm.config.state == .running {
				self.vm.captureWindowImage { image in
					self.previewImage = image
					self.vm.updatePreview(img: image)
				}
			}
		//}
	}

	func isLoading() -> Bool {
		return self.vm.config.state == .running && self.previewImage == nil
	}

	func onFocusEvent(focused: Bool) {
		DispatchQueue.main.async {
			let change = focused != self.isFocused
			self.isFocused = focused
			if self.isFocused && self.vm.config.state == .running {
				if change {
					self.updatePreview()
				}
				self.startTimer()
			} else {
				self.stopTimer()
			}
		}
	}
}
