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
	],
	targets: [
		.target(
			name: "MachmanAPI",
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.target(
			name: "MachmanCore",
			dependencies: ["MachmanAPI"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
	]
)
