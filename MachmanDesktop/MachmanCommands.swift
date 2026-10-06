//
//  MachmanCommands.swift
//  MachmanDesktop
//
//  The menu bar's commands. What each menu holds — titles, shortcuts, dimming, help, what an
//  item does — is MenuModel's (MachmanDesktopCore, Q19); this renders its entries for the
//  KEY window (P22) and carries out what needs the app. Each window publishes which window it
//  is (focusedSceneValue machmanWindow) and its inspector toggle, so with a torn-off
//  terminal in front, ⌘S saves that terminal and Paste Items pastes into its VM. Items that
//  ask first (a sheet, a dialog) bring the main window forward, where those live.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore
import MachmanDesktopUI

struct MachmanCommands: Commands {
	// Read when an item runs; what the menus show comes from `menu`, which publishes only
	// when that changes (P9).
	let connection: DaemonConnection
	@ObservedObject var menu: MenuModel
	@ObservedObject var textEditing: TextEditingMonitor
	@Binding var selection: String?
	@FocusedValue(\.machmanWindow) private var window
	@FocusedBinding(\.machmanInspector) private var inspectorShown
	// Paste Items' enablement follows the pasteboard (H25); the paste itself reads fresh.
	@ObservedObject private var pasteboard = PasteboardWatch.general
	@Environment(\.openWindow) private var openWindow

	var body: some Commands {
		let window = keyWindow
		let content = menu.content(
			window: window, inspectorShown: inspectorShown,
			editingText: textEditing.isEditingText,
			canPaste: pasteboard.snapshot.canPasteAnything)
		CommandGroup(before: .sidebar) {
			entries(content.view, window)
		}
		CommandMenu("Run") {
			entries(content.run, window)
		}
		CommandMenu("Stop") {
			entries(content.stop, window)
		}
		// Entity clipboard beside the standard text Copy/Paste (Option variants so
		// text-field editing keeps plain ⌘C/⌘V).
		CommandGroup(after: .pasteboard) {
			entries(content.edit, window)
		}
		// Replacing, not before: SwiftUI's own New Window items (the torn-tab group's too)
		// go, and ⌘N belongs to New VM.
		CommandGroup(replacing: .newItem) {
			entries(content.file, window)
		}
	}

	// Windows say which they are through focusedSceneValue. Should a key main window not
	// have published yet, its scene id ("main") still names it; anything else stays nil.
	private var keyWindow: CommandWindow? {
		if let window { return window }
		return NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true ? .main : nil
	}

	@ViewBuilder
	private func entries(_ entries: [MenuEntry], _ window: CommandWindow?) -> some View {
		ForEach(entries) { entry in
			switch entry {
			case .item(let item):
				button(item, window)
			case .divider:
				Divider()
			case .submenu(_, let title, let items):
				Menu(title) {
					ForEach(items) { button($0, window) }
				}
			}
		}
	}

	private func button(_ item: MenuItem, _ window: CommandWindow?) -> some View {
		Button(action: { run(item, window) }) {
			if let symbol = item.symbol {
				Label(item.title, systemImage: symbol)
			} else {
				Text(item.title)
			}
		}
		.keyboardShortcut(item.shortcut)
		.disabled(!item.isEnabled)
		.help(item.help ?? "")
	}

	// Dialogs and sheets show on the main window: bring it forward first when the item says.
	private func run(_ item: MenuItem, _ window: CommandWindow?) {
		if item.showsMainWindow { openWindow(id: "main") }
		switch menu.perform(item.action, window: window) {
		case .toggleInspector?:
			inspectorShown?.toggle()
		case .closeKeyWindow?:
			NSApp.keyWindow?.performClose(nil)
		case .selected(let name)?:
			selection = name
		case .copy(let items)?:
			EntityClipboard.write(items)
		case .paste(let vm)?:
			guard let viewModel = connection.viewModel else { return }
			AddFlows.paste(
				entities: EntityClipboard.read(), fileURLs: AddFlows.pasteboardFileURLs(),
				into: vm, viewModel: viewModel)
		case .saveTerminal(let terminal)?:
			connection.viewModel?.saveTerminalTranscript(of: terminal)
		case nil:
			break
		}
	}
}
