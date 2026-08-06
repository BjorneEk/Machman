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
	],
	targets: [
		.target(
			name: "MachmanAPI",
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// Core depends on the client lib too: the daemon's router speaks to its vmhost
		// children through RemoteMachman, exactly like any other client.
		.target(
			name: "MachmanCore",
			dependencies: ["MachmanAPI", "MachmanClient"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// The client half: RemoteMachman over the socket. Depends on the API only —
		// anything linking this stays free of Virtualization/AppKit.
		.target(
			name: "MachmanClient",
			dependencies: ["MachmanAPI"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
	]
)
