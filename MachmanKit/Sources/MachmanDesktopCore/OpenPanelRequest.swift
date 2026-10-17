//
//  OpenPanelRequest.swift
//  MachmanDesktopCore
//
//  One "choose a file or a folder" question, as the add flows ask it (Q21): what may be
//  picked, and what the panel says it is for (H63): a message — one imperative sentence, no
//  final period, the VM's name bare — and its button's Title Case prompt. AppKit-free:
//  MachmanDesktopUI's OpenPanels asks it with an NSOpenPanel, and a test answers it itself,
//  so a flow's cancel and pick paths run without a panel. SavePanelRequest is Save
//  Terminal's "save as" question, asked the same way.
//

import Foundation
import UniformTypeIdentifiers
import MachmanAPI

public struct OpenPanelRequest: Equatable, Sendable {
	public enum Pick: Equatable, Sendable {
		case file, folder
	}

	public let pick: Pick
	// The file types offered; empty for any file.
	public let contentTypes: [UTType]
	public let message: String
	public let prompt: String

	public init(pick: Pick, contentTypes: [UTType] = [], message: String, prompt: String) {
		self.pick = pick
		self.contentTypes = contentTypes
		self.message = message
		self.prompt = prompt
	}

	// Add Existing Disk…: a disk image, or any file (the flow then asks copy or reference).
	public static func existingDisk(vm: String) -> OpenPanelRequest {
		OpenPanelRequest(
			pick: .file, contentTypes: [.diskImage, .data],
			message: "Choose a disk image to add to \(vm)", prompt: "Add")
	}

	public static func mountFolder(vm: String) -> OpenPanelRequest {
		OpenPanelRequest(
			pick: .folder, message: "Choose a folder to share with \(vm)", prompt: "Add")
	}

	// A kernel or initramfs has no type of its own to filter by.
	public static func kernelFile(_ role: KernelRole, vm: String) -> OpenPanelRequest {
		OpenPanelRequest(
			pick: .file,
			message: role == .kernel
				? "Choose a kernel image for \(vm)" : "Choose an initramfs for \(vm)",
			prompt: "Add")
	}

	// The New Mac flow's and the Install macOS sheet's restore image. Typed by its extension:
	// the declared com.apple.itunes.ipsw where the Mac has it, else a dynamic type that
	// still filters by the extension.
	public static let restoreImage = OpenPanelRequest(
		pick: .file,
		contentTypes: [UTType(filenameExtension: "ipsw", conformingTo: .data) ?? .data],
		message: "Choose a macOS restore image to install", prompt: "Install")
}

// One "save as" question: the name the panel suggests and the types it saves as.
public struct SavePanelRequest: Equatable, Sendable {
	public let name: String
	public let contentTypes: [UTType]

	public init(name: String, contentTypes: [UTType]) {
		self.name = name
		self.contentTypes = contentTypes
	}

	// A terminal's transcript, named for its VM and tab ("Debian hvc0.log"); a slash or a
	// colon in either name, which a file name can't hold, becomes "-".
	public static func terminalTranscript(vm: String, tab: String) -> SavePanelRequest {
		let name = "\(vm) \(tab)"
			.replacingOccurrences(of: "/", with: "-")
			.replacingOccurrences(of: ":", with: "-")
		return SavePanelRequest(name: name + ".log", contentTypes: [.plainText])
	}

	// A terminal no tab holds any more.
	public static let anyTranscript = SavePanelRequest(
		name: "terminal.log", contentTypes: [.plainText])
}
