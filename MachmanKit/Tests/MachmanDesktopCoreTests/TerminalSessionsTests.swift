//
//  TerminalSessionsTests.swift
//  MachmanDesktopCoreTests
//
//  The terminal registry is one lifecycle for both transports (Q3): a serial terminal and an
//  ssh session are dropped, reconciled away and renamed by the same paths. The fakes never
//  connect a socket or start ssh (FakeTerminalController).
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct TerminalSessionsTests {
	private let console = SerialPortRef(kind: .console, index: 0)
	private let session = SSHSessionRef(title: "Session 1")

	// One serial and one ssh controller for Debian, both live.
	private func harnessWithBothKinds() async -> DesktopHarness {
		let h = await DesktopHarness.make()
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: "/var/empty/machman-sample/c0.sock",
			profile: h.profiles.defaultProfile)
		h.terminals.ensureSSHController(
			vm: "Debian", ref: session, arguments: ["debian.machman"],
			profile: h.profiles.defaultProfile)
		_ = await eventually {
			h.terminals.controller(for: .terminal(console), vm: "Debian") != nil
				&& h.terminals.controller(for: .ssh(session), vm: "Debian") != nil
		}
		return h
	}

	@Test func dropEndsASerialAndAnSSHControllerAlike() async throws {
		let h = await harnessWithBothKinds()
		h.terminals.renameSSHSession(vm: "Debian", ref: session, to: "build box")
		let serial = try #require(
			h.terminals.controller(vm: "Debian", ref: console) as? FakeTerminalController)
		let ssh = try #require(
			h.terminals.sshController(vm: "Debian", ref: session) as? FakeTerminalController)
		h.terminals.drop(.terminal(console), vm: "Debian")
		h.terminals.drop(.ssh(session), vm: "Debian")
		#expect(h.terminals.controller(vm: "Debian", ref: console) == nil)
		#expect(h.terminals.sshController(vm: "Debian", ref: session) == nil)
		#expect(serial.disconnects == 1)
		#expect(ssh.disconnects == 1)
		#expect(h.terminals.sshSessionName(vm: "Debian", ref: session) == "Session 1")
	}

	@Test func aGoneVMTakesBothKindsWithIt() async {
		let h = await harnessWithBothKinds()
		h.terminals.renameSSHSession(vm: "Debian", ref: session, to: "build box")
		h.terminals.reconcile(vms: [])
		#expect(h.terminals.controller(for: .terminal(console), vm: "Debian") == nil)
		#expect(h.terminals.controller(for: .ssh(session), vm: "Debian") == nil)
		#expect(h.controllers.allSatisfy { $0.disconnects == 1 })
		#expect(h.terminals.sshSessionName(vm: "Debian", ref: session) == "Session 1")
	}

	@Test func renameMovesBothKindsAndTheirNames() async {
		let h = await harnessWithBothKinds()
		h.terminals.renameSSHSession(vm: "Debian", ref: session, to: "build box")
		let serial = h.terminals.controller(for: .terminal(console), vm: "Debian")
		let ssh = h.terminals.controller(for: .ssh(session), vm: "Debian")
		h.terminals.renameVM(from: "Debian", to: "Debian 2")
		#expect(h.terminals.controller(for: .terminal(console), vm: "Debian 2") === serial)
		#expect(h.terminals.controller(for: .ssh(session), vm: "Debian 2") === ssh)
		#expect(h.terminals.controller(for: .terminal(console), vm: "Debian") == nil)
		#expect(h.terminals.sshSessionName(vm: "Debian 2", ref: session) == "build box")
		#expect(h.controllers.allSatisfy { $0.disconnects == 0 })
	}

	// K7: a session keeps its own pick, and follows edits of the profile it uses — the
	// default while it picked none — and of no other. It used to skip every edit, although
	// Settings promises that open terminals pick up the changes at once.
	@Test("T30: an SSH session follows edits of the profile it uses, not of others")
	func sshSessionsFollowTheirOwnProfile() async throws {
		let h = await harnessWithBothKinds()
		let serial = try #require(
			h.terminals.controller(vm: "Debian", ref: console) as? FakeTerminalController)
		let ssh = try #require(
			h.terminals.sshController(vm: "Debian", ref: session) as? FakeTerminalController)
		var edited = h.profiles.defaultProfile
		edited.fontSize += 2
		h.profiles.update(edited)
		h.terminals.reapplyLiveProfiles(h.profiles)
		#expect(serial.liveApplies == 1)
		#expect(ssh.liveApplies == 1)

		// Its own pick: edits of that profile reach it, edits of the default no longer do.
		var picked = h.profiles.addProfile()
		h.terminals.applySSHProfile(vm: "Debian", ref: session, id: picked.id, profile: picked)
		#expect(ssh.liveApplies == 2)
		edited.fontSize += 2
		h.profiles.update(edited)
		h.terminals.reapplyLiveProfiles(h.profiles)
		#expect(ssh.liveApplies == 2)
		#expect(serial.liveApplies == 2)
		picked.colors.background = "#123456"
		h.profiles.update(picked)
		h.terminals.reapplyLiveProfiles(h.profiles)
		#expect(ssh.liveApplies == 3)
		#expect(serial.liveApplies == 2)
	}

	@Test("T30: a session whose profile is deleted falls back to the default")
	func aSessionsDeletedProfileFallsBackToTheDefault() async throws {
		let h = await harnessWithBothKinds()
		let ssh = try #require(
			h.terminals.sshController(vm: "Debian", ref: session) as? FakeTerminalController)
		var picked = h.profiles.addProfile()
		picked.colors.background = "#123456"
		h.profiles.update(picked)
		h.terminals.applySSHProfile(vm: "Debian", ref: session, id: picked.id, profile: picked)
		#expect(ssh.liveApplies == 1)
		h.profiles.delete(id: picked.id)
		h.terminals.reapplyLiveProfiles(h.profiles)
		#expect(ssh.liveApplies == 2)   // back on the default's colours
		#expect(h.terminals.sshSessionProfileID(vm: "Debian", ref: session) == nil)
	}

	// Runs once everything the main queue already holds has run (the registry's deferred
	// re-apply included).
	private func mainQueueTurn() async {
		await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
	}

	// P38: the registry follows the store itself, so no view has to be mounted (a torn window
	// with the main window closed), and a tab is re-applied only when its own live settings
	// change: re-setting a font clears the terminal's selection.
	@Test func profileChangesReachATerminalOnlyWhenItsLiveSettingsChange() async throws {
		let h = await harnessWithBothKinds()
		h.terminals.follow(h.profiles)
		let serial = try #require(
			h.terminals.controller(vm: "Debian", ref: console) as? FakeTerminalController)
		let ssh = try #require(
			h.terminals.sshController(vm: "Debian", ref: session) as? FakeTerminalController)
		var edited = h.profiles.defaultProfile
		edited.fontSize += 2
		h.profiles.update(edited)
		#expect(await eventually { serial.liveApplies == 1 })

		// Nothing live changed for this port: another profile to edit, a pending delete, a
		// startup-only edit.
		var other = h.profiles.addProfile()
		h.profiles.editingProfileID = other.id
		h.profiles.requestDelete(id: other.id)
		var startupOnly = h.profiles.defaultProfile
		startupOnly.scrollback = 2_000
		h.profiles.update(startupOnly)
		await mainQueueTurn()
		#expect(serial.liveApplies == 1)

		// The port moves to a profile with other colours, then to its twin.
		other.colors.background = "#123456"
		h.profiles.update(other)
		h.profiles.associate(vm: "Debian", ref: console, to: other.id)
		#expect(await eventually { serial.liveApplies == 2 })
		let twin = h.profiles.duplicate(id: other.id)
		h.profiles.associate(vm: "Debian", ref: console, to: twin.id)
		await mainQueueTurn()
		#expect(serial.liveApplies == 2)
		#expect(ssh.liveApplies == 1)   // the session uses the default: its font edit only (T30)
	}

	// MARK: - Serial reconnect (T25: a closed or refused socket, the tab's banner)

	@Test func aDisconnectedSerialTabReconnectsOnItsOwnController() async throws {
		let h = await harnessWithBothKinds()
		let serial = try #require(
			h.terminals.controller(vm: "Debian", ref: console) as? FakeTerminalController)
		serial.disconnect()
		h.terminals.reconnectSerial(vm: "Debian", ref: console, socketPath: "/var/empty/c0.sock")
		#expect(serial.connected)
		#expect(serial.connectedPaths.last == "/var/empty/c0.sock")
		#expect(serial.notes.count == 1)
		#expect(serial.notes.first?.hasPrefix("reconnected ") == true)
		#expect(h.terminals.controller(vm: "Debian", ref: console) === serial)
	}

	// A refused socket (the vmhost is gone, the list still has its path): no "reconnected"
	// line however often Reconnect is clicked.
	@Test func aRefusedSerialReconnectLeavesNoLine() async throws {
		let h = await harnessWithBothKinds()
		let serial = try #require(
			h.terminals.controller(vm: "Debian", ref: console) as? FakeTerminalController)
		serial.disconnect()
		serial.refusesConnect = true
		let path = "/var/empty/c0.sock"
		for _ in 0..<3 { h.terminals.reconnectSerial(vm: "Debian", ref: console, socketPath: path) }
		#expect(!serial.connected)
		#expect(serial.connectedPaths.suffix(3) == [path, path, path])
		#expect(serial.notes.isEmpty)
	}

	@Test func aConnectedSerialTabIgnoresReconnect() async throws {
		let h = await harnessWithBothKinds()
		let serial = try #require(
			h.terminals.controller(vm: "Debian", ref: console) as? FakeTerminalController)
		let paths = serial.connectedPaths
		h.terminals.reconnectSerial(vm: "Debian", ref: console, socketPath: "/var/empty/c0.sock")
		#expect(serial.connectedPaths == paths)
		#expect(serial.notes.isEmpty)
	}

	// The tab's onChange(of: socket) path: a controller left disconnected takes the new socket.
	@Test func aMovedSocketReconnectsADisconnectedTab() async throws {
		let h = await harnessWithBothKinds()
		let serial = try #require(
			h.terminals.controller(vm: "Debian", ref: console) as? FakeTerminalController)
		serial.disconnect()
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: "/var/empty/moved.sock",
			profile: h.profiles.defaultProfile)
		#expect(serial.connectedPaths.last == "/var/empty/moved.sock")
		#expect(h.terminals.controller(vm: "Debian", ref: console) === serial)
	}

	// MARK: - Reconnect (Q4: the tab's banner and the session inspector share it)

	@Test func aDeadSessionReconnectsOnItsOwnController() async throws {
		let vm = Samples.sshReadyLinux()
		let h = await DesktopHarness.make([vm])
		let arguments = try #require(SSHCommand.arguments(for: vm))
		h.terminals.ensureSSHController(
			vm: "Debian", ref: session, arguments: arguments, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.sshController(vm: "Debian", ref: session) != nil })
		let fake = try #require(
			h.terminals.sshController(vm: "Debian", ref: session) as? FakeTerminalController)
		fake.disconnect()
		#expect(h.terminals.reconnectSSHSession(vm: vm, ref: session, profiles: h.profiles))
		#expect(fake.connected)
		#expect(fake.notes.count == 1)
		#expect(h.terminals.sshController(vm: "Debian", ref: session) === fake)
	}

	@Test func aDeadSessionWhoseSSHCantStartGetsNoLine() async throws {
		let vm = Samples.sshReadyLinux()
		let h = await DesktopHarness.make([vm])
		let arguments = try #require(SSHCommand.arguments(for: vm))
		h.terminals.ensureSSHController(
			vm: "Debian", ref: session, arguments: arguments, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.sshController(vm: "Debian", ref: session) != nil })
		let fake = try #require(
			h.terminals.sshController(vm: "Debian", ref: session) as? FakeTerminalController)
		fake.disconnect()
		fake.refusesConnect = true
		#expect(h.terminals.reconnectSSHSession(vm: vm, ref: session, profiles: h.profiles))
		#expect(!fake.connected)
		#expect(fake.notes.isEmpty)
	}

	@Test func aSessionWithoutAnAddressStaysDown() async throws {
		let vm = Samples.linux("Debian")
		let h = await DesktopHarness.make([vm])
		h.terminals.ensureSSHController(
			vm: "Debian", ref: session, arguments: ["debian.machman"],
			profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.sshController(vm: "Debian", ref: session) != nil })
		let fake = try #require(
			h.terminals.sshController(vm: "Debian", ref: session) as? FakeTerminalController)
		fake.disconnect()
		#expect(!h.terminals.reconnectSSHSession(vm: vm, ref: session, profiles: h.profiles))
		#expect(!fake.connected)
	}
}
