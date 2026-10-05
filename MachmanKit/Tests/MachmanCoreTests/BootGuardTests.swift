//
//  BootGuardTests.swift
//  MachmanTests
//
//  PR15: the one cross-VM boot guard, pure over what the caller knows of the other VMs. No
//  shared MAC with a running VM or an earlier start; no writable disk file another VM has —
//  or may have — attached.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct BootGuardTests {
	private let mac = "aa:bb:cc:55:00:01"

	@Test func aRunningVMsMACRefuses() throws {
		let candidate = BootGuard.Candidate(name: "alpha", mac: mac)
		let error = try #require(throws: MachmanError.self) {
			try BootGuard.checkMAC(candidate, among: [
				BootGuard.Other(name: "beta", role: .running, mac: mac),
			])
		}
		#expect(error.code == .macConflict)
		#expect(error.message == "alpha and the running VM \u{201C}beta\u{201D} share MAC "
			+ "address \(mac), so one of them would lose networking")
		// Its own entry never counts.
		try BootGuard.checkMAC(candidate, among: [
			BootGuard.Other(name: "alpha", role: .running, mac: mac),
		])
	}

	@Test func amongStartsTheEarlierWins() throws {
		let starts = [
			BootGuard.Other(name: "alpha", role: .starting(order: 1), mac: mac),
			BootGuard.Other(name: "beta", role: .starting(order: 2), mac: mac),
		]
		try BootGuard.checkMAC(
			BootGuard.Candidate(name: "alpha", mac: mac, order: 1), among: starts)
		let error = try #require(throws: MachmanError.self) {
			try BootGuard.checkMAC(
				BootGuard.Candidate(name: "beta", mac: mac, order: 2), among: starts)
		}
		#expect(error.message.contains("\u{201C}alpha\u{201D}, which is starting"))
	}

	@Test func aDiskAttachedOrMaybeAttachedRefuses() throws {
		let candidate = BootGuard.Candidate(name: "alpha", disks: ["/d/a.raw", "/d/b.raw"])
		var error = try #require(throws: MachmanError.self) {
			try BootGuard.checkDisks(candidate, among: [
				BootGuard.Other(
					name: "kept", role: .running, mac: nil, attached: ["/d/b.raw"]),
			])
		}
		#expect(error.code == .invalidState)
		#expect(error.message == "kept is running with b.raw attached — stop kept before "
			+ "starting alpha")
		error = try #require(throws: MachmanError.self) {
			try BootGuard.checkDisks(candidate, among: [
				BootGuard.Other(
					name: "kept", role: .running, mac: nil, mayHaveAttached: ["/d/a.raw"]),
			])
		}
		#expect(error.message == "kept may still have a.raw attached — stop kept before "
			+ "starting alpha")
		try BootGuard.checkDisks(candidate, among: [
			BootGuard.Other(name: "kept", role: .running, mac: nil, attached: ["/d/c.raw"]),
		])
	}
}
