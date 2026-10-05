//
//  VMClaimsTests.swift
//  MachmanTests
//
//  PR14: the one table of what holds a VM's files in the daemon. A start claims its name
//  alone; a release frees exactly the claim it names; the starts' MACs keep their order.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct VMClaimsTests {
	@Test func aStartHoldsItsNameAlone() throws {
		let claims = VMClaims()
		let token = try claims.claim("alpha", .starting, mac: "aa:bb:cc:00:00:01")
		#expect(claims.startingNames == ["alpha"])

		let error = try #require(throws: MachmanError.self) {
			_ = try claims.claim("alpha", .starting)
		}
		#expect(error.code == .invalidState)
		#expect(error.message == "alpha is already starting")
		#expect(throws: MachmanError.self) { _ = try claims.claim("alpha", .saving) }
		_ = try claims.claim("beta", .starting)   // another VM is not held

		claims.release(token)
		#expect(claims.claims(on: "alpha").isEmpty)
		_ = try claims.claim("alpha", .starting)
	}

	@Test func aReleaseFreesOnlyItsOwnClaim() throws {
		let claims = VMClaims()
		let first = claims.insert("alpha", .starting)
		claims.insert("alpha", .saving)
		claims.release(first)
		#expect(claims.claims(on: "alpha").map(\.kind) == [.saving])
		claims.release(first)   // twice is harmless
		#expect(claims.claims(on: "alpha").count == 1)
	}

	@Test func startsKeepTheirMACsInClaimOrder() throws {
		let claims = VMClaims()
		_ = try claims.claim("beta", .starting, mac: "aa:bb:cc:00:00:02")
		_ = try claims.claim("alpha", .starting, mac: "aa:bb:cc:00:00:01")
		_ = try claims.claim("gamma", .saving)
		let macs = claims.startMACs
		#expect(macs.keys.sorted() == ["alpha", "beta"])
		#expect(try #require(macs["beta"]).order < #require(macs["alpha"]).order)
		#expect(claims.startingNames == ["alpha", "beta", "gamma"])
	}
}
