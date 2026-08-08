//
//  VMHostBootstrap.swift
//  MachmanCore
//
//  The whole vmhost program: a daemon that owns exactly one VM. Reuses the engine wholesale —
//  single-VM registry, LocalMachman, MachmanServer on the per-VM socket — plus a manual
//  NSApplication (the target is an LSUIElement app with no SwiftUI scene). The process exits
//  when its VM stops; Machmand spawns a fresh one per start.
//

import Foundation
import AppKit
import MachmanAPI

public enum VMHostBootstrap {
	// Never returns: hands the thread to NSApplication.run().
	@MainActor
	public static func run(
		dataDir: String, vmName: String, socketPath: String, daemonVersion: String
	) -> Never {
		machmanVMDir = dataDir

		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)

		let registry = VMRegistry(only: vmName)
		guard registry.vm(named: vmName) != nil else {
			MachmanLogger.log(.passiveError, "no VM named '\(vmName)' in \(dataDir)")
			exit(64)
		}
		let api = LocalMachman(registry: registry)
		let server = MachmanServer(
			api: api, socketPath: socketPath, daemonVersion: "\(daemonVersion)-vmhost")
		do {
			try server.start()
		} catch {
			MachmanLogger.log(.passiveError, "cannot serve \(socketPath): \(error)")
			exit(65)
		}

		let lifecycle = Lifecycle()
		// Exit when the VM stops (after having run). The idle backstop covers a spawn whose
		// start never happened — e.g. the daemon died between spawn and forward.
		Task { @MainActor in
			let stream = registry.events.stream()
			for await event in stream {
				guard case .stateChanged(let vm, let state) = event, vm == vmName else {
					continue
				}
				if state.isRunning {
					lifecycle.hadRunning = true
				}
				if state == .stopped, lifecycle.hadRunning {
					try? await Task.sleep(for: .milliseconds(300))   // let replies/events flush
					server.stop()
					exit(0)
				}
			}
		}
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(180))
			if !lifecycle.hadRunning {
				server.stop()
				exit(0)
			}
		}

		app.run()
		exit(0)
	}

	@MainActor
	private final class Lifecycle {
		var hadRunning = false
	}
}
