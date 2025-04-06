//
//  PreviewView.swift
//  Machman
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

	init(viewModel: VMListViewModel) {
		self.viewModel = viewModel
	}

	var body: some View {
		VStack {
			if let img = self.viewModel.preview() {
				Image(nsImage: img)
					.resizable()
					.aspectRatio(16/9, contentMode: .fit)
					.cornerRadius(5)
					//.onTapGesture {
					// viewModel.updatePreview()
					//	}
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
