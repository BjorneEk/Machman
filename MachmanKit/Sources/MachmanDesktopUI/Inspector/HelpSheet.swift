//
//  HelpSheet.swift
//  MachmanDesktopUI
//
//  The help sheets' one look (the Guest Setup guide, the mount guide): a fixed frame, the
//  +20% type scale, a title row, whatever the sheet puts above its page (tabs, the run-as
//  choice), the page scrolling, and a footer line beside Done. The building blocks below
//  are the only things a page is made of, so the sheets cannot drift apart.
//

import SwiftUI
import MachmanUI

enum HelpSheetType {
	static let title: CGFloat = 19
	static let text: CGFloat = 15.5
	static let small: CGFloat = 13
}

struct HelpSheetFrame<Header: View, Page: View>: View {
	let symbol: String
	let title: String
	var footer: String?
	var height: CGFloat = 620
	@ViewBuilder let header: () -> Header
	@ViewBuilder let page: () -> Page
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 8) {
				Image(systemName: symbol)
					.font(.system(size: 24))
					.foregroundStyle(.secondary)
				Text(title)
					.font(.system(size: HelpSheetType.title, weight: .semibold))
				Spacer()
			}
			header()
			ScrollView {
				VStack(alignment: .leading, spacing: 12) {
					page()
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, 2)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			Divider()
			HStack(alignment: .firstTextBaseline) {
				if let footer {
					Text(footer)
						.font(.system(size: HelpSheetType.small))
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		// FIXED size on purpose: a flexible ScrollView inside a sheet makes the AppKit
		// hosting view renegotiate during layout.
		.frame(width: 560, height: height)
	}
}

// MARK: - Building blocks

struct HelpIntro: View {
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View {
		Text(text)
			.font(.system(size: HelpSheetType.text))
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
	}
}

struct HelpSectionTitle: View {
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View {
		Text(text)
			.font(.system(size: HelpSheetType.text, weight: .semibold))
			.padding(.top, 2)
	}
}

struct HelpBullet: View {
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("•").font(.system(size: HelpSheetType.text))
			Text(text)
				.font(.system(size: HelpSheetType.text))
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

struct HelpOptionRow: View {
	let flag: String
	let meaning: String
	init(_ flag: String, _ meaning: String) {
		self.flag = flag
		self.meaning = meaning
	}
	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text(flag)
				.font(.system(size: HelpSheetType.small, design: .monospaced))
				.frame(width: 180, alignment: .leading)
			Text(meaning)
				.font(.system(size: HelpSheetType.small))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

struct HelpStep: View {
	let number: Int
	let text: String
	init(_ number: Int, _ text: String) {
		self.number = number
		self.text = text
	}
	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("\(number)")
				.font(.system(size: HelpSheetType.small, weight: .semibold))
				.monospacedDigit()
				.frame(width: 20, height: 20)
				.background(Circle().fill(Color.primary.opacity(0.08)))
			Text(text)
				.font(.system(size: HelpSheetType.text))
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

// A copyable command, indented under its step. The caller escalates it.
struct HelpCommand: View {
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View {
		HStack(alignment: .top) {
			Text(text)
				.font(.system(size: HelpSheetType.small, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 6)
			CopyToClipboardButton(text, tooltip: "Copy")
		}
		.padding(7)
		.background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
		.padding(.leading, 28)
	}
}

struct HelpNote: View {
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View {
		Text(text)
			.font(.system(size: HelpSheetType.small))
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.leading, 28)
	}
}
