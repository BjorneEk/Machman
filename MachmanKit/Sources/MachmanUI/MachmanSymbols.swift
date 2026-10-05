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
	public static let delete = "trash"
	public static let copy = "doc.on.doc"
	public static let copyDone = "checkmark"
	public static let duplicateVM = "plus.square.on.square"
	public static let info = "info.circle"
	// Opens a setup-guide sheet (the console Setup Guide button).
	public static let help = "questionmark.circle"
	// Do it again: a new MAC address, address discovery, an SSH retry.
	public static let regenerate = "arrow.clockwise"

	// MARK: - Boot config
	public static let bootMacTab = "apple.logo"

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
	public static let saveToFile = "arrow.down.doc"
	// Canvas tabs and terminals
	public static let tabTerminal = "terminal"
	public static let tabConfig = "gearshape"
	public static let closeTab = "xmark"
	public static let reloadTerminal = "arrow.clockwise.circle"

	// MARK: - Safe mode
	public static let safe = "shield.lefthalf.filled"

	// MARK: - App chrome
	public static let menuBarExtra = "desktopcomputer"
	public static let daemonUnreachable = "bolt.horizontal.circle"

	// MARK: - Settings tabs
	public static let settingsAppearance = "paintpalette"
	public static let settingsTerminal = "terminal"
	public static let settingsBehavior = "gearshape"

	// MARK: - Overhaul additions (1.0.4 UI)
	public static let vm = "desktopcomputer"            // tree root / picker rows
	public static let shield = "shield"                 // outline for the safe-start glyph
	public static let rename = "pencil"
	public static let showInFinder = "arrow.up.forward.app"
	public static let search = "magnifyingglass"
	public static let more = "ellipsis"                 // row quick-action menus
	public static let pickerChevron = "chevron.down"    // fades in on the VM indicator
	public static let back = "chevron.left"             // popover sub-view back button
	public static let disclosure = "chevron.right"      // tree group chevron (turns down open)
	public static let selectedItem = "checkmark"        // picker row's current selection
	public static let templateBlank = "square.dashed"   // New VM blank-template tile
	public static let warning = "exclamationmark.triangle.fill"
	public static let confirm = "checkmark.circle.fill"
	public static let activeEntry = "checkmark.circle.fill"   // active kernel/initramfs
	public static let externalReference = "link"        // referenced (not owned) file badge
	public static let splitRight = "rectangle.split.2x1"
	public static let moveHere = "arrow.down.square"    // drop-zone "Move Here" label
	public static let installDownload = "arrow.down.circle" // download-latest install
	public static let installFromFile = "doc"           // install from an IPSW file
	public static let newWindow = "macwindow.on.rectangle"
	public static let inspectorToggle = "sidebar.right" // also the empty inspector's glyph
	public static let activity = "clock.arrow.circlepath"   // toolbar activity list
	public static let bootEFI = "gearshape.2"           // EFI boot-kind badge
	public static let mount = "folder.fill"
	public static let mountSSHFS = "externaldrive.badge.wifi"     // sshfs-kind mount badge
	public static let automounted = "arrow.triangle.2.circlepath" // boot-automounted badge
	public static let initramfs = "archivebox.fill"
	public static let kernelFile = "doc.text"           // kernel-file drop preview row

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
	public static let deviceGuestSetup = "shippingbox.fill"   // THE installer (1.0.7)
	public static let installerGroup = "shippingbox"

	// Add-popover tiles
	public static let addDiskNew = "externaldrive.badge.plus"
	public static let addDiskExisting = "doc.badge.plus"
	public static let addMount = "folder.badge.plus"
}
