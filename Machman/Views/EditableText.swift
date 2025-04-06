//
//  EditableText.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI

struct EditableText: View {
	@Binding var text: String
	let onSubmit: () -> Void
	let onChange: (String) -> Void


	@State private var isEditing = false
	@FocusState private var isFocused: Bool

	init(
		_ text: Binding<String>,
		onSubmit: @escaping () -> Void = { },
		onChange: @escaping (String) -> Void = { _ in }
	) {
		self._text = text
		self.onSubmit = onSubmit
		self.onChange = onChange
	}

	var body: some View {
		Group {
			if isEditing {
				TextField("", text: $text, onCommit: {
					isEditing = false
					onSubmit()
				})
				.focused($isFocused)

				.frame(maxWidth: 200)
				.onAppear {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
						isFocused = true
					}
				}
				.onChange(of: text) {
					onChange(text)
				}
			} else {
				Text(text)
					.help("double click to edit")
					.onTapGesture(count: 2) {
						isEditing = true
					}
			}
		}
	}
}
#Preview {
}
