//
//  PreviewView.swift
//  MachmanDesktop
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI
struct PreviewWidthKey: PreferenceKey {
	static var defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		// We want the maximum width measured
		value = max(value, nextValue())
	}
}

struct PreviewView: View {
	@ObservedObject private var viewModel: VMListViewModel
	// Observed so a new preview frame re-renders THIS view only; the image itself is read back
	// through viewModel.preview(), which now reads from the same store.
	@ObservedObject private var previews: PreviewStore

	init(viewModel: VMListViewModel, previews: PreviewStore) {
		self.viewModel = viewModel
		self.previews = previews
	}

	var body: some View {
		VStack {
			if let img = self.viewModel.preview() {
				Image(nsImage: img)
					.resizable()
					.aspectRatio(16/9, contentMode: .fit)
					.cornerRadius(5)
			} else if self.viewModel.isLoading() {
					Rectangle()
						.fill(Color.black)
						.aspectRatio(16/9, contentMode: .fit)
						.cornerRadius(12)
						.overlay(
							ProgressView()
						)
			} else {
				Rectangle()
					.fill(Color.black)
					.aspectRatio(16/9, contentMode: .fit)
					.cornerRadius(12)
					.overlay(
						Text("VM Preview unavailable")
							.foregroundColor(.white)
							.bold()
					)
			}
			Spacer()
		}
		.background(
			GeometryReader { proxy in
				Color.clear
				.preference(key: PreviewWidthKey.self, value: proxy.size.width)
			}
		)
	}
}


#Preview {
}
