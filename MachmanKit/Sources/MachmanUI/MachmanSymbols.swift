//
//  MachmanSymbols.swift
//  MachmanUI
//
//  The one place an SF Symbol name may appear. Views reference concepts, so swapping a glyph
//  is a one-line edit here and every call site follows. (The wire contract stays UI-free:
//  none of this belongs in MachmanAPI.)
//

import Foundation

public enum MachmanSymbols {
	// MARK: - VM run state (StatusIcon vocabulary)
	public static let vmRunningWindowed = "macwindow"
	public static let vmRunningHeadless = "terminal"
	public static let vmStopped = "pause.fill"

	// MARK: - Run / stop
	public static let start = "play.fill"   // was play.circle — bolder, and the safe-start
	                                        // composite needs a bare triangle in its shield
	public static let startHeadless = "play.slash"
	public static let shutDown = "power"
	public static let forceStop = "stop.circle"

	// MARK: - VM windows
	public static let openWindow = "macwindow.badge.plus"
	// NOT macwindow.badge.minus — that name does not exist in the system symbol set
	// (verified via NSImage(systemSymbolName:)); the badge-family sibling does.
	public static let closeWindow = "rectangle.badge.xmark"

	// MARK: - Generic actions
	public static let add = "plus"
	public static let addFilled = "plus.circle.fill"
	public static let delete = "trash"
	public static let browse = "folder.fill.badge.plus"
	public static let copy = "doc.on.doc"
	public static let copyDone = "checkmark"
	public static let duplicateVM = "plus.square.on.square"
	public static let cancel = "xmark.circle.fill"
	public static let info = "info.circle"
	// Opens a setup-guide sheet (the console Setup Guide button).
	public static let help = "questionmark.circle"
	// Reserved: rendered by the MAC-regenerate button (phase 3.2).
	public static let regenerate = "arrow.clockwise"

	// MARK: - Boot config
	public static let bootDefaultTab = "gearshape"
	public static let bootMacTab = "apple.logo"
	public static let macOSInstalled = "apple.logo"
	public static let kernelBootToggle = "bolt.fill"
	public static let kernelCommandLine = "terminal.fill"
	public static let macInstallDownload = "icloud.and.arrow.down"

	// MARK: - Hardware
	public static let cpu = "cpu.fill"
	public static let memory = "memorychip.fill"
	public static let network = "network"

	// MARK: - Disks & mounts
	// Copy a referenced external disk into the VM (take ownership).
	public static let promoteDisk = "square.and.arrow.down"
	public static let diskStorage = "externaldrive.fill"
	public static let diskImage = "externaldrive.fill.badge.icloud"
	public static let diskISO = "externaldrive.connected.to.line.below.fill"
	public static let diskName = "internaldrive.fill"
	public static let diskSize = "gauge.with.needle"

	// MARK: - Serial ports
	public static let serialConsole = "terminal"
	public static let serialUart = "cable.connector"
	public static let serialPort = "rectangle.connected.to.line.below"
	public static let saveToFile = "arrow.down.doc"
	public static let serialConnect = "bolt.horizontal.circle"
	public static let serialDisconnect = "bolt.horizontal.circle.fill"
	// Serial detail tabs
	public static let tabInfo = "info.circle"
	public static let tabTerminal = "terminal"
	public static let tabAdvanced = "wrench.and.screwdriver"
	// Per-VM tabbed pane
	public static let tabConfig = "gearshape"
	public static let closeTab = "xmark"
	public static let infoPanel = "sidebar.right"
	public static let terminalProfile = "paintpalette"
	public static let reloadTerminal = "arrow.clockwise.circle"
	// Sidebar disclosure chevrons
	public static let disclosureCollapsed = "chevron.right"
	public static let disclosureExpanded = "chevron.down"

	// MARK: - History
	public static let uptime = "clock"
	public static let totalRuntime = "hourglass"
	public static let lastUsed = "clock.arrow.circlepath"
	public static let created = "calendar.badge.plus"

	// MARK: - Start policy & safe mode (unsafe reserved: rendered by phase 6)
	public static let safe = "shield.lefthalf.filled"
	public static let unsafe = "shield.slash"
	public static let autostart = "power.circle"

	// MARK: - App chrome
	public static let menuBarExtra = "desktopcomputer"
	public static let daemonUnreachable = "bolt.horizontal.circle"

	// MARK: - Overhaul additions (1.0.4 UI). Additive only: existing tokens keep their
	// glyphs until the redesigned views that adopt new values land with them.
	public static let vm = "desktopcomputer"            // tree root / picker rows
	public static let shield = "shield"                 // outline for the safe-start glyph
	public static let paste = "doc.on.clipboard"
	public static let rename = "pencil"
	public static let showInFinder = "arrow.up.forward.app"
	public static let search = "magnifyingglass"
	public static let more = "ellipsis"                 // row quick-action menus
	public static let pickerChevron = "chevron.down"    // fades in on the VM indicator
	public static let back = "chevron.left"             // popover sub-view back button
	public static let selectedItem = "checkmark"        // picker row's current selection
	public static let templateBlank = "square.dashed"   // New VM blank-template tile
	public static let warning = "exclamationmark.triangle.fill"
	public static let confirm = "checkmark.circle.fill"
	public static let activeEntry = "checkmark.circle.fill"   // active kernel/initramfs
	public static let externalReference = "link"        // referenced (not owned) file badge
	public static let splitRight = "rectangle.split.2x1"
	public static let moveHere = "arrow.down.square"    // drop-zone "Move Here" label
	public static let installDownload = "arrow.down.circle" // download-latest install
	public static let newWindow = "macwindow.on.rectangle"
	public static let sidebarToggle = "sidebar.left"
	public static let inspectorToggle = "sidebar.right" // successor name for infoPanel
	public static let bootEFI = "gearshape.2"           // EFI boot-kind badge
	public static let mount = "folder.fill"
	public static let initramfs = "archivebox.fill"
	public static let kernelFile = "doc.text"           // kernel-file drop preview row
	public static let logging = "doc.text.below.ecg"

	// Guest devices (mirrors MachmanCore/VMDevices assembly; SF has no trackpad/penguin —
	// trackpad approximates, the kernel penguin is the custom TuxIcon view).
	public static let deviceGroup = "puzzlepiece.extension"   // the tree's Devices parent
	public static let deviceGraphics = "display"
	public static let deviceKeyboard = "keyboard"
	public static let deviceTrackpad = "rectangle.and.hand.point.up.left"
	public static let devicePointer = "computermouse"
	public static let deviceAudioIn = "mic"
	public static let deviceAudioOut = "speaker.wave.2"
	public static let deviceClipboard = "clipboard"
	public static let deviceEntropy = "die.face.5"
	public static let deviceRosetta = "translate"
	// Installer-package metaphor — the terminal glyphs belong to the consoles themselves.
	public static let deviceLoginInstaller = "shippingbox.fill"
	public static let deviceSSHSetup = "key.fill"

	// Add-popover tiles
	public static let addDiskNew = "externaldrive.badge.plus"
	public static let addDiskExisting = "doc.badge.plus"
	public static let addMount = "folder.badge.plus"
}
