// swift-tools-version: 6.0
import PackageDescription

// MachmanKit — shared code for the machmand refactor.
//
//   MachmanAPI   the wire contract: DTOs + MachmanControlling + canonical JSON coding.
//                Imports Foundation ONLY — never Virtualization or AppKit. Everything a
//                client (GUI, CLI, non-Swift) needs to talk to the daemon, nothing more.
//   MachmanCore  the VM engine behind the protocol.
//   MachmanDesktopCore  the desktop's view models and stores (no views, no windows): what the
//                headless view-model tests drive. Never MachmanCore or Virtualization.
//
let package = Package(
	name: "MachmanKit",
	platforms: [.macOS(.v15)],
	products: [
		.library(name: "MachmanAPI", targets: ["MachmanAPI"]),
		.library(name: "MachmanCore", targets: ["MachmanCore"]),
		.library(name: "MachmanClient", targets: ["MachmanClient"]),
		.library(name: "MachmanUI", targets: ["MachmanUI"]),
		.library(name: "MachmanDesktopCore", targets: ["MachmanDesktopCore"]),
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
			exclude: [
				"GuestScripts/assemble.sh",   // the dev-loop assembler, not a payload
				"GuestScripts/dist",          // its (gitignored) output
			],
			resources: [
				// The unified installer, one module per concern; EmbeddedScript.assembled
				// concatenates them in this order at payload-write time (assemble.sh is the
				// same concatenation for the shellcheck/docker dev loop).
				.embedInCode("GuestScripts/setup/00-prelude.sh"),
				.embedInCode("GuestScripts/setup/05-lib.sh"),
				.embedInCode("GuestScripts/setup/10-usage.sh"),
				.embedInCode("GuestScripts/setup/15-args.sh"),
				.embedInCode("GuestScripts/setup/20-detect.sh"),
				.embedInCode("GuestScripts/setup/30-state.sh"),
				.embedInCode("GuestScripts/setup/40-console.sh"),
				.embedInCode("GuestScripts/setup/45-kernel-console.sh"),
				.embedInCode("GuestScripts/setup/50-ssh.sh"),
				.embedInCode("GuestScripts/setup/52-reverse.sh"),
				.embedInCode("GuestScripts/setup/55-sshfs.sh"),
				.embedInCode("GuestScripts/setup/60-automount-virtiofs.sh"),
				.embedInCode("GuestScripts/setup/65-automount-sshfs.sh"),
				.embedInCode("GuestScripts/setup/80-report.sh"),
				.embedInCode("GuestScripts/setup/90-main.sh"),
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
		// The desktop client's logic: view models + stores over MachmanControlling. Anything
		// that talks to the window server, the pasteboard, panels or NSWorkspace lives with the
		// views, so every type here runs headless under swift test. Never MachmanCore or
		// Virtualization; MachmanClient is allowed if connection logic ever moves in.
		.target(
			name: "MachmanDesktopCore",
			dependencies: ["MachmanAPI", "MachmanUI"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),

		// MARK: Tests — headless, run through scripts/test.sh (never `swift test` by hand).
		//
		// MachmanTestGuard: a load-time constructor that refuses to start a test process outside
		// a per-run sandbox, so no run can resolve the .dev or Release Machman paths.
		// MachmanTestSupport: the sandbox's paths for tests (scratch dir, suite id, fake home).
		// Every test target depends on the support target, which links the guard.
		.target(name: "MachmanTestGuard", path: "Tests/MachmanTestGuard"),
		.target(
			name: "MachmanTestSupport",
			dependencies: ["MachmanTestGuard"],
			path: "Tests/MachmanTestSupport",
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// StubMachman (an in-memory MachmanControlling). Deliberately NOT linked to the guard:
		// the render tool builds its scenes from it outside any test run.
		.target(
			name: "MachmanFixtures",
			dependencies: ["MachmanAPI"],
			path: "Tests/MachmanFixtures",
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.testTarget(
			name: "MachmanAPITests",
			dependencies: ["MachmanAPI", "MachmanTestSupport"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.testTarget(
			name: "MachmanClientTests",
			dependencies: ["MachmanAPI", "MachmanClient", "MachmanTestSupport"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.testTarget(
			name: "MachmanCoreTests",
			dependencies: [
				"MachmanAPI", "MachmanClient", "MachmanCore", "MachmanFixtures",
				"MachmanTestSupport",
			],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.testTarget(
			name: "MachmanUITests",
			dependencies: ["MachmanAPI", "MachmanUI", "MachmanTestSupport"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
	]
)
