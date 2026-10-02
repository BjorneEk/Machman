//
//  TreeGroup.swift
//  MachmanDesktopUI
//
//  The device tree's scaffold: TreeGroup, a section's disclosure group and its label, and
//  `.treeRow`, the chrome every entry row shares. A section supplies only what differs: its
//  icon, title, count, accessory, menus and rows.
//

import SwiftUI
import MachmanUI
import MachmanDesktopCore

// Group parents are dimmed and NOT selectable (no tag — selection skips them); their add
// actions live in a row-level context menu on the label. `accessory` renders as a trailing
// control before the count (the SSH group's +). `selectable` is for the groups that ARE a
// thing in their own right and carry an inspector (Kernel, SSH): they keep a tag and full
// opacity. `parked` dims a whole group further (Kernel and Initramfs while kernel boot is
// off); a nil `count` draws none. No @Environment here — the label reads the theme: an
// environment read in the view that owns a List row's DisclosureGroup made AppKit warn of
// a reentrant NSTableView delegate operation on every tree update.
struct TreeGroup<Icon: View, MenuItems: View, Accessory: View, Content: View>: View {
	private let node: SidebarNode
	private let title: String
	private let count: Int?
	private let selectable: Bool
	private let parked: Bool
	@Binding private var isExpanded: Bool
	private let icon: () -> Icon
	private let menu: () -> MenuItems
	private let accessory: () -> Accessory
	private let content: () -> Content

	init(
		_ node: SidebarNode, title: String, count: Int?, selectable: Bool = false,
		parked: Bool = false, isExpanded: Binding<Bool>,
		@ViewBuilder icon: @escaping () -> Icon,
		@ViewBuilder menu: @escaping () -> MenuItems = { EmptyView() },
		@ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
		@ViewBuilder content: @escaping () -> Content
	) {
		self.node = node
		self.title = title
		self.count = count
		self.selectable = selectable
		self.parked = parked
		_isExpanded = isExpanded
		self.icon = icon
		self.menu = menu
		self.accessory = accessory
		self.content = content
	}

	var body: some View {
		let disclosure = DisclosureGroup(isExpanded: $isExpanded) {
			content()
		} label: {
			TreeGroupLabel(
				title: title, count: count, icon: icon, menu: menu, accessory: accessory)
		}
		if selectable {
			disclosure
				.tag(node)
				.opacity(parked ? 0.45 : 1)
		} else {
			disclosure.opacity(parked ? 0.45 : MachmanColors.dimmedRowOpacity)
		}
	}
}

// A group's label row: icon, title, the trailing accessory and count, and the add menu.
struct TreeGroupLabel<Icon: View, MenuItems: View, Accessory: View>: View {
	let title: String
	let count: Int?
	let icon: () -> Icon
	let menu: () -> MenuItems
	let accessory: () -> Accessory
	@Environment(\.machmanTheme) private var theme

	var body: some View {
		HStack(spacing: 6) {
			icon()
			Text(title).fontWeight(.medium)
			Spacer()
			accessory()
			if let count {
				Text("\(count)")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.monospacedDigit()
			}
		}
		.font(.system(size: theme.metrics.rowFontSize))
		.frame(height: theme.metrics.treeRowHeight)
		.contextMenu { menu() }
	}
}

// The usual group icon: the section's symbol, secondary.
struct TreeGroupSymbol: View {
	let symbol: String
	@Environment(\.machmanTheme) private var theme

	var body: some View {
		Image(systemName: symbol)
			.font(.system(size: theme.metrics.iconSize))
			.foregroundStyle(.secondary)
	}
}

extension TreeGroup where Icon == TreeGroupSymbol {
	init(
		_ node: SidebarNode, symbol: String, title: String, count: Int,
		selectable: Bool = false, isExpanded: Binding<Bool>,
		@ViewBuilder menu: @escaping () -> MenuItems = { EmptyView() },
		@ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
		@ViewBuilder content: @escaping () -> Content
	) {
		self.init(
			node, title: title, count: count, selectable: selectable, isExpanded: isExpanded,
			icon: { TreeGroupSymbol(symbol: symbol) }, menu: menu, accessory: accessory,
			content: content)
	}
}

// The chrome every entry row shares, always in this order: the dim of an inactive entry, the
// row font and height, the plain click of a row that opens something (simultaneous with the
// List's own click, which keeps selecting), the tag the List selects it by, and its menu.
struct TreeRow<MenuItems: View>: ViewModifier {
	let node: SidebarNode
	let opacity: Double
	let onClick: (() -> Void)?
	let menu: () -> MenuItems
	@Environment(\.machmanTheme) private var theme

	@ViewBuilder
	func body(content: Content) -> some View {
		let row = content
			.opacity(opacity)
			.font(.system(size: theme.metrics.rowFontSize))
			.frame(height: theme.metrics.treeRowHeight)
		if let onClick {
			row
				.contentShape(Rectangle())
				.simultaneousGesture(TapGesture().onEnded { onClick() })
				.tag(node)
				.contextMenu { menu() }
		} else {
			row
				.tag(node)
				.contextMenu { menu() }
		}
	}
}

extension View {
	func treeRow<MenuItems: View>(
		_ node: SidebarNode, opacity: Double = 1, onClick: (() -> Void)? = nil,
		@ViewBuilder menu: @escaping () -> MenuItems
	) -> some View {
		modifier(TreeRow(node: node, opacity: opacity, onClick: onClick, menu: menu))
	}
}
