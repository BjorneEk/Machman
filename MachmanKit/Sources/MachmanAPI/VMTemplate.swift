//
//  VMTemplate.swift
//  MachmanAPI
//
//  The starting device sets vm.create offers (1.0.4). The raw value is the wire spelling of
//  vm.create's `template`; this enum and docs/ipc-protocol.md are the documented list (there
//  is no discovery call). A daemon refuses a name it doesn't know.
//

import Foundation

public enum VMTemplate: String, CaseIterable, Sendable {
	// No devices and no console port: add exactly what you need.
	case blank
	// The implied EFI device set plus one console; no disk (add your own). What an absent
	// template means, too.
	case `default`
	// The Mac guest device set minus the trackpad, which needs macOS boot (add it after the
	// install). The VM still boots EFI until macOS is installed.
	case mac
}
