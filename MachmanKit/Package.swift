// swift-tools-version: 6.0
import PackageDescription

// MachmanKit — shared code for the machmand refactor.
//
//   MachmanAPI   the wire contract: DTOs + MachmanControlling + canonical JSON coding.
//                Imports Foundation ONLY — never Virtualization or AppKit. Everything a
//                client (GUI, CLI, non-Swift) needs to talk to the daemon, nothing more.
//   MachmanCore  (added in a later step) the VM engine behind the protocol.
//
let package = Package(
	name: "MachmanKit",
	platforms: [.macOS(.v15)],
	products: [
		.library(name: "MachmanAPI", targets: ["MachmanAPI"]),
		.library(name: "MachmanCore", targets: ["MachmanCore"]),
		.library(name: "MachmanClient", targets: ["MachmanClient"]),
		.library(name: "MachmanUI", targets: ["MachmanUI"]),
	],
	targets: [
		.target(
			name: "MachmanAPI",
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// Core depends on the client lib too: the daemon's router speaks to its vmhost
		// children through RemoteMachman, exactly like any other client.
		// GuestScripts/*.sh are the installer payloads Machman serves to guests. They are
		// embedded in the binary (no bundle lookup, so they work identically from the
		// desktop, the daemon, the vmhost and the tests) and stay real shell sources:
		// runnable, lintable, and parameterless — everything per-VM rides the machman.env
		// the writer generates beside them (GuestInstaller.swift).
		.target(
			name: "MachmanCore",
			dependencies: ["MachmanAPI", "MachmanClient"],
			resources: [
				.embedInCode("GuestScripts/ssh-setup.sh"),
				.embedInCode("GuestScripts/console-login.sh"),
				.embedInCode("GuestScripts/machman-lib.sh"),
			],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// The client half: RemoteMachman over the socket. Depends on the API only —
		// anything linking this stays free of Virtualization/AppKit.
		.target(
			name: "MachmanClient",
			dependencies: ["MachmanAPI"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// Shared SwiftUI vocabulary + controls for the Machman UIs (desktop and daemon menu).
		// Depends on MachmanAPI only — never MachmanCore.
		.target(
			name: "MachmanUI",
			dependencies: ["MachmanAPI"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
	]
)
