//
//  TerminalSettingsView.swift
//  MachmanDesktopUI
//
//  The terminal-profile editor (the Terminal tab of the app Settings window). Pick a profile to
//  edit, rename / duplicate / delete it (deleting asks first), or start from a colour preset;
//  edit its font, colours, cursor and behaviour. Every edit writes straight through to the
//  store, which republishes so any open terminal picks up the live changes at once
//  (startup-only changes wait for a Reload). A live preview terminal on the right shows the
//  result as you type.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanDesktopCore

struct TerminalSettingsView: View {
	@ObservedObject var store: TerminalProfileStore
	@StateObject private var preview: TerminalPreviewController

	init(store: TerminalProfileStore) {
		_store = ObservedObject(wrappedValue: store)
		_preview = StateObject(wrappedValue: TerminalPreviewController(profile: .oneDarkDefault))
	}

	// The profile currently being edited (falls back to the default).
	private var editingID: UUID { store.editingProfileID ?? store.defaultProfile.id }
	private var current: TerminalProfile { store.profile(id: editingID) ?? store.defaultProfile }

	var body: some View {
		VStack(spacing: 0) {
			header
				.padding(.horizontal)
				.padding(.vertical, 8)
			Divider()
			HStack(spacing: 0) {
				form.frame(width: 340)
				Divider()
				previewPane
			}
		}
		.onAppear { preview.apply(current) }
		.onChange(of: current) { _, p in preview.apply(p) }
		// H9: a profile is deleted only after this asks; there is no undo.
		.confirmationDialog(
			"Delete “\(store.pendingDeletion?.name ?? "")”?", isPresented: deletionShown,
			titleVisibility: .visible, presenting: store.pendingDeletion
		) { p in
			Button("Delete", role: .destructive) { store.delete(id: p.id) }
			Button("Cancel", role: .cancel) {}
		} message: { _ in
			Text("Ports that use it switch to \(store.defaultProfile.name).")
		}
	}

	private var deletionShown: Binding<Bool> {
		Binding(
			get: { store.pendingDeletion != nil },
			set: { if !$0 { store.pendingDeletion = nil } })
	}

	// MARK: - Header (choose / manage the profile)

	private var header: some View {
		HStack(spacing: 8) {
			Picker("Profile", selection: selectionBinding) {
				ForEach(store.profiles) { p in Text(p.name).tag(p.id) }
			}
			.labelsHidden()   // still the name VoiceOver reads (H48)
			.frame(maxWidth: 180)
			TextField("Name", text: binding(\.name))
				.textFieldStyle(.roundedBorder)
				.frame(maxWidth: 150)
			Menu("Preset") {
				ForEach(TerminalTheme.allCases) { theme in
					Button(theme.rawValue) { applyPreset(theme) }
				}
			}
			.frame(maxWidth: 100)
			Spacer()
			// Image-only: each help text is also the VoiceOver label (H32).
			Button { newProfile() } label: { Image(systemName: MachmanSymbols.add) }
				.help("New profile")
				.accessibilityLabel("New profile")
			Button { store.duplicate(id: current.id) } label: {
				Image(systemName: MachmanSymbols.duplicateVM)
			}
			.help("Duplicate profile")
			.accessibilityLabel("Duplicate profile")
			Button(role: .destructive) { store.requestDelete(id: current.id) } label: {
				Image(systemName: MachmanSymbols.delete)
			}
			.help("Delete profile…")
			.accessibilityLabel("Delete profile…")
			.disabled(!store.canDelete(id: current.id))
		}
	}

	// MARK: - Form (the settings)

	private var form: some View {
		Form {
			Section("Font") {
				Picker("Family", selection: binding(\.fontName)) {
					ForEach(fontFamilies, id: \.self) { Text(TerminalFonts.label(for: $0)).tag($0) }
				}
				Stepper(
					"Size: \(Int(current.fontSize))",
					value: binding(\.fontSize), in: 8...48, step: 1)
			}
			Section("Colors") {
				ColorPicker("Text", selection: colorBinding(\.colors.foreground),
					supportsOpacity: false)
				ColorPicker("Background", selection: colorBinding(\.colors.background),
					supportsOpacity: false)
				ColorPicker("Cursor", selection: colorBinding(\.colors.cursor),
					supportsOpacity: false)
				ColorPicker("Selection", selection: colorBinding(\.colors.selectionBackground),
					supportsOpacity: false)
				VStack(alignment: .leading, spacing: 4) {
					Text("ANSI palette").font(.caption).foregroundColor(.secondary)
					LazyVGrid(
						columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8),
						spacing: 6
					) {
						ForEach(0..<16, id: \.self) { i in
							ColorPicker(
								"ANSI color \(i)", selection: ansiBinding(i), supportsOpacity: false)
								.labelsHidden()
								.help("ANSI color \(i)")
						}
					}
				}
			}
			Section {
				Picker("Cursor style", selection: binding(\.cursor)) {
					ForEach(TerminalCursor.allCases, id: \.self) { Text($0.label).tag($0) }
				}
			} header: {
				Text("Cursor")
			} footer: {
				Text("Cursor style applies when a terminal is created — Reload to change an open one.")
					.font(.caption2)
			}
			Section {
				// The profile clamps what is typed; the label says to what. A narrow field leaves
				// the label its line.
				LabeledContent {
					TextField("Scrollback", value: binding(\.scrollback), format: .number)
						.labelsHidden()
						.multilineTextAlignment(.trailing)
						.frame(width: 90)
				} label: {
					Text(Self.scrollbackLabel).fixedSize(horizontal: true, vertical: false)
				}
				Toggle("Convert newlines (LF → CRLF)", isOn: binding(\.convertEol))
				TextField("$TERM", text: binding(\.termName))
				Stepper("Tab width: \(current.tabStopWidth)",
					value: binding(\.tabStopWidth), in: 1...16)
			} header: {
				Text("Behavior")
			} footer: {
				Text("Scrollback, newline conversion, $TERM and tab width apply when a terminal is "
					+ "(re)created — use Reload on an open terminal.")
					.font(.caption2)
			}
			Section("Advanced") {
				Toggle("Option key sends Meta/Esc", isOn: binding(\.optionAsMeta))
				Toggle("Report mouse to the guest", isOn: binding(\.mouseReporting))
			}
		}
		.formStyle(.grouped)
	}

	private var previewPane: some View {
		VStack(spacing: 0) {
			SerialTerminalHost(controller: preview.controller)
				.id(ObjectIdentifier(preview.controller))
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.padding(6)
			Divider()
			Text("Live preview")
				.font(.caption).foregroundColor(.secondary)
				.frame(maxWidth: .infinity, alignment: .center)
				.padding(4)
		}
	}

	// MARK: - Actions

	private func newProfile() {
		let p = store.addProfile()
		store.editingProfileID = p.id
	}

	private func applyPreset(_ theme: TerminalTheme) {
		var p = current
		p.colors = theme.colors
		store.update(p)
	}

	// MARK: - Bindings (write straight through to the store)

	private var selectionBinding: Binding<UUID> {
		Binding(get: { editingID }, set: { store.editingProfileID = $0 })
	}

	private func binding<T>(_ kp: WritableKeyPath<TerminalProfile, T>) -> Binding<T> {
		Binding(
			get: { current[keyPath: kp] },
			set: { newValue in
				var p = current
				p[keyPath: kp] = newValue
				store.update(p)
			})
	}

	private func colorBinding(_ kp: WritableKeyPath<TerminalProfile, String>) -> Binding<Color> {
		Binding(
			get: { Color(nsColor: NSColor(hexColor: current[keyPath: kp]) ?? .black) },
			set: { newColor in
				var p = current
				p[keyPath: kp] = Self.hexString(from: newColor)
				store.update(p)
			})
	}

	private func ansiBinding(_ i: Int) -> Binding<Color> {
		Binding(
			get: {
				let hex = current.colors.ansi.indices.contains(i)
					? current.colors.ansi[i] : "#000000"
				return Color(nsColor: NSColor(hexColor: hex) ?? .black)
			},
			set: { newColor in
				var p = current
				if p.colors.ansi.indices.contains(i) {
					p.colors.ansi[i] = Self.hexString(from: newColor)
					store.update(p)
				}
			})
	}

	// The installed families, plus the profile's own font when it is missing — listed (so the
	// picker has a row for it) but labelled "(not installed)" (H19).
	private var fontFamilies: [String] {
		let installed = TerminalFonts.families
		if installed.contains(current.fontName) { return installed }
		return (installed + [current.fontName]).sorted()
	}

	private static let scrollbackLabel =
		"Scrollback (up to \(TerminalProfile.scrollbackRange.upperBound.formatted()) lines)"

	private static func hexString(from color: Color) -> String {
		let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
		return formatHexColor(RGB8(
			r: UInt8((ns.redComponent * 255).rounded()),
			g: UInt8((ns.greenComponent * 255).rounded()),
			b: UInt8((ns.blueComponent * 255).rounded())))
	}
}
