//
//  KernelDraft.swift
//  MachmanAPI
//
//  What a VM's kernel-boot draft (BootInfo.kernel) holds (N3, K1): it outlives kernel boot
//  while it keeps something — a kernel or initramfs file, or a command line — and goes once it
//  holds nothing. One rule for the engine that drops it, the desktop that draws its sections
//  and the stub that stands in for the engine.
//

import Foundation

extension KernelSettings {
	// A kernel or initramfs path ("" names none).
	public var holdsFile: Bool {
		!kernelPath.isEmpty || !(initrdPath ?? "").isEmpty
	}

	// A command line of more than whitespace.
	public var holdsCommandLine: Bool {
		!commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	public var holdsNothing: Bool { !holdsFile && !holdsCommandLine }
}
