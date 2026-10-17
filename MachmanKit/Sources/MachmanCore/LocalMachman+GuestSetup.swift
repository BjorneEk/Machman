//
//  LocalMachman+GuestSetup.swift
//  MachmanCore
//
//  Guest Setup's engine routes: forget the report (vm.setup.reset), serve the installer to an
//  installed guest (vm.setup.serve), and the script store (S67) — pin a VM to a stored script
//  (vm.setup.pin) and import a script file into the store (host.setupScripts.import).
//

import Foundation
import MachmanAPI

extension LocalMachman {
	// MARK: - Guest setup (1.0.7)

	public func resetSetup(vm name: String) async throws -> VMInfo {
		let vm = try lookup(name)
		try vm.config.resetSetup()
		registry.events.emit(.setupChanged(vm: name))
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func setSetupServed(vm name: String, serve: Bool) async throws -> VMInfo {
		let vm = try lookup(name)
		// The persisted choice (only meaningful once installed — fresh guests always
		// serve). ON fills the pre-registered share dirs live; OFF is deferred by
		// design: content, if any, leaves with the run (teardown's removePayload) —
		// never yanked from under a running guest.
		if vm.config.setup != nil, vm.config.setup?.reinstallRequested != serve {
			vm.config.setup?.reinstallRequested = serve
			try vm.config.saveVMConfig()
		}
		if serve, vm.runtime != nil {
			_ = try GuestSetupInstaller.writePayload(for: vm.config)
		}
		registry.events.emit(.setupChanged(vm: name))
		return info(for: vm)
	}

	// MARK: - The script store (S67)

	public func setSetupScript(vm name: String, id: String) async throws -> VMInfo {
		let vm = try lookup(name)
		let store = GuestSetupStore.current
		try vm.config.pinSetupScript(id, store: store)
		// A share serving right now carries the new script at once; a guest run in progress
		// keeps reading the file it opened (the write replaces it).
		if vm.runtime != nil, vm.config.servesSetupPayload {
			_ = try GuestSetupInstaller.writePayload(for: vm.config, store: store)
		}
		registry.events.emit(.setupChanged(vm: name))
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func importSetupScript(path: String, vm: String?) async throws
		-> GuestSetupScriptInfo {
		// A file the user picked may sit on a slow volume: read and stored off the actor.
		let store = GuestSetupStore.current
		let entry = try await Task.detached(priority: .userInitiated) {
			try store.importScript(atPath: path, vm: vm)
		}.value
		registry.events.emit(.listChanged)
		return store.wireInfo(entry)
	}
}
