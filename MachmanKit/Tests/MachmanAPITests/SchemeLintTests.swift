//
//  SchemeLintTests.swift
//  MachmanAPITests
//
//  Lints of the shared Xcode schemes: no scheme or target tests through Xcode (the suite runs
//  headless through scripts/test.sh, W0-1 — a hosted test bundle launched the app), and only
//  the "MachmanDesktop (ASan)" scheme runs the address sanitizer (R3W1-1, U2).
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct SchemeLintTests {
	@Test("W0-1: no shared scheme or project target holds a test bundle")
	func noTestBundles() throws {
		let schemes = try XcodeSchemes.shared()
		#expect(schemes.count >= 3, "\(schemes.map(\.name))")
		for scheme in schemes {
			#expect(Self.testReferences(scheme).isEmpty, "\(scheme.name) tests a bundle or plan")
			// The same verdict with the (empty) <Testables> block removed — the shape Xcode
			// leaves once nothing is listed, as in the user's working copy.
			let stripped = try XcodeSchemes.Scheme(
				name: scheme.name, data: Self.withoutTestables(scheme.document))
			#expect(stripped.nodes("//Testables").isEmpty)
			#expect(Self.testReferences(stripped).isEmpty, "\(scheme.name) without <Testables>")
		}
		// The query sees a listed test bundle (provoked with an in-memory scheme).
		let provoked = try XcodeSchemes.Scheme(name: "provoked", data: Data("""
			<Scheme><TestAction><Testables><TestableReference skipped = "NO">\
			</TestableReference></Testables></TestAction></Scheme>
			""".utf8))
		#expect(Self.testReferences(provoked).count == 1)
		for target in try XcodeProject.load().targets {
			#expect(!target.productType.contains("bundle.unit-test"), "\(target.name)")
			#expect(!target.productType.contains("bundle.ui-testing"), "\(target.name)")
		}
		let plans = RepoFiles.files(under: [""], extension: "xctestplan")
		#expect(plans.isEmpty, "\(plans.map(RepoFiles.relativePath))")
	}

	@Test("R3W1-1: only the ASan scheme turns on the address sanitizer")
	func addressSanitizerOnlyInItsScheme() throws {
		let schemes = try XcodeSchemes.shared()
		let asan = try #require(schemes.first { $0.name == "MachmanDesktop (ASan)" })
		let launch = asan.nodes("//LaunchAction/@enableAddressSanitizer").map(\.stringValue)
		#expect(launch == ["YES"])
		for scheme in schemes where scheme.name != asan.name {
			#expect(scheme.nodes("//@enableAddressSanitizer[.='YES']").isEmpty, "\(scheme.name)")
		}
		let project = try XcodeProject.load()
		let levels = [("project", project.projectSettings)]
			+ project.targets.map { ($0.name, $0.settings) }
		for (level, settings) in levels {
			for (configuration, values) in settings {
				for key in ["CLANG_ADDRESS_SANITIZER", "ENABLE_ADDRESS_SANITIZER"] {
					#expect(values[key] != "YES", "\(level) \(configuration) sets \(key)")
				}
			}
		}
	}

	static func testReferences(_ scheme: XcodeSchemes.Scheme) -> [XMLNode] {
		scheme.nodes("//TestableReference") + scheme.nodes("//TestPlanReference")
	}

	// An in-memory copy of the scheme with every <Testables> element removed.
	static func withoutTestables(_ document: XMLDocument) throws -> Data {
		let copy = try XMLDocument(data: document.xmlData)
		for case let element as XMLElement in try copy.nodes(forXPath: "//Testables") {
			element.detach()
		}
		return copy.xmlData
	}
}
