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
	public static let start = "play.circle"
	public static let startHeadless = "play.slash"
	public static let shutDown = "power"
	public static let forceStop = "stop.circle"

	// MARK: - VM windows
	public static let openWindow = "macwindow.badge.plus"
	public static let closeWindow = "macwindow.badge.minus"

	// MARK: - Generic actions
	public static let add = "plus"
	public static let addFilled = "plus.circle.fill"
	public static let delete = "trash"
	public static let browse = "folder.fill.badge.plus"
	public static let copy = "doc.on.doc"
	public static let copyDone = "checkmark"
	public static let duplicateVM = "plus.square.on.square"
	public static let cancel = "xmark.circle.fill"
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
}
