//
//  TreeGroup.swift
//  MachmanDesktopUI
//
//  The device tree's scaffold: TreeGroup, a section's label row and its rows, and `.treeRow`,
//  the chrome every entry row shares. A section supplies only what differs: its icon, title,
//  count, accessory, menus and rows.
//

import SwiftUI
import MachmanUI
import MachmanDesktopCore

// Group labels are dimmed and NOT selectable (no tag — selection skips them); their add
// actions live in a row-level context menu on the label. `accessory` renders as a trailing
// control before the count (the SSH group's +). `selectable` is for the groups that ARE a
// thing in their own right and carry an inspector (Kernel, SSH): they keep a tag and full
// opacity. `parked` dims a whole group further (Kernel and Initramfs while kernel boot is
// off); a nil `count` draws none. `folds` false (nothing in it, TreeSection.folds) draws the
// label as a leaf: no chevron, nothing below it.
// Plain List rows, not a DisclosureGroup (T26): SwiftUI expands an outline group lazily as
// its row comes into view, and AppKit's row-height estimate re-enters itself under that
// expansion ("reentrant operation in its NSTableView delegate", an assert to come). The label
// row carries the chevron; the group's rows follow it, indented, while it is expanded.
struct TreeGroup<Icon: View, MenuItems: View, Accessory: View, Content: View>: View {
	private let node: SidebarNode
	private let title: String
	private let count: Int?
	private let selectable: Bool
	private let parked: Bool
	private let folds: Bool
	@Binding private var isExpanded: Bool
	private let icon: () -> Icon
	private let menu: () -> MenuItems
	private let accessory: () -> Accessory
	private let content: () -> Content

	init(
		_ node: SidebarNode, title: String, count: Int?, selectable: Bool = false,
		parked: Bool = false, folds: Bool = true, isExpanded: Binding<Bool>,
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
		self.folds = folds
		_isExpanded = isExpanded
		self.icon = icon
		self.menu = menu
		self.accessory = accessory
		self.content = content
	}

	// Only an unselectable label dims: its rows carry their own state (a disabled disk dims
	// itself, an enabled one doesn't), so the group's dim never reaches them (H36). Parked
	// dims the whole group.
	var body: some View {
		Group {
			label
				.opacity(selectable || parked ? 1 : MachmanColors.dimmedRowOpacity)
			if folds && isExpanded {
				content()
					.padding(.leading, TreeIndent.rows)
			}
		}
		.opacity(parked ? 0.45 : 1)
	}

	@ViewBuilder
	private var label: some View {
		let row = TreeGroupLabel(
			title: title, count: count, isExpanded: folds ? $isExpanded : nil, icon: icon,
			menu: menu, accessory: accessory)
		if selectable {
			row.tag(node)
		} else {
			row
		}
	}
}

// Where the flat tree's rows start, lined up with the outline layout they replace (T26): the
// root row after the outline's disclosure gutter, a group's chevron in that gutter, a
// group's rows one level in.
enum TreeIndent {
	static let root: CGFloat = 9
	static let chevron: CGFloat = -2
	static let rows: CGFloat = 21
}

// A group's label row: chevron, icon, title, the trailing accessory and count, the add menu.
// A leaf (nil `isExpanded`) keeps the chevron's room, so its icon lines up with the others.
struct TreeGroupLabel<Icon: View, MenuItems: View, Accessory: View>: View {
	let title: String
	let count: Int?
	let isExpanded: Binding<Bool>?
	let icon: () -> Icon
	let menu: () -> MenuItems
	let accessory: () -> Accessory
	@Environment(\.machmanTheme) private var theme

	var body: some View {
		HStack(spacing: 1.5) {
			if let isExpanded {
				TreeGroupChevron(title: title, isExpanded: isExpanded)
			} else {
				Color.clear.frame(width: TreeGroupChevron.width, height: 1)
			}
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
		}
		.padding(.leading, TreeIndent.chevron)
		.font(.system(size: theme.metrics.rowFontSize))
		.frame(height: theme.metrics.treeRowHeight)
		.contextMenu { menu() }
	}
}

// The chevron a group folds and unfolds by: right when collapsed, down when expanded.
struct TreeGroupChevron: View {
	static let width: CGFloat = 10
	let title: String
	@Binding var isExpanded: Bool

	var body: some View {
		Button {
			withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
		} label: {
			Image(systemName: MachmanSymbols.disclosure)
				.font(.system(size: 8.5, weight: .heavy))
				.foregroundStyle(.primary.opacity(0.75))
				.rotationEffect(.degrees(isExpanded ? 90 : 0))
				.frame(width: Self.width, height: 16)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
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
		selectable: Bool = false, folds: Bool = true, isExpanded: Binding<Bool>,
		@ViewBuilder menu: @escaping () -> MenuItems = { EmptyView() },
		@ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
		@ViewBuilder content: @escaping () -> Content
	) {
		self.init(
			node, title: title, count: count, selectable: selectable, folds: folds,
			isExpanded: isExpanded, icon: { TreeGroupSymbol(symbol: symbol) }, menu: menu,
			accessory: accessory, content: content)
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
