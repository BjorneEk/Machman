//
//  BuildSettingsLintTests.swift
//  MachmanAPITests
//
//  Lints of the Xcode project's build settings, next to the production-safety tests: what the
//  three apps are called (never plain "Machman"), their copyright line, the .dev bundle ids
//  that keep a Debug build off the Release suite, and one marketing version that never falls
//  below the desktop's daemon floor.
//

import Foundation
import Testing
import MachmanAPI
import MachmanTestSupport

// L1: lint (repo files).
struct BuildSettingsLintTests {
	static let apps: [(target: String, name: String, idSuffix: String)] = [
		("MachmanDesktop", "Machman Desktop", ""),
		("MachmanAgent", "Machman Agent", ".agent"),
		("MachmanVMHost", "Machman VM", ".vmhost"),
	]
	static let configurations = ["Debug", "Release"]

	@Test("Q18: the repo root holds the Xcode project and MachmanKit")
	func repoRootIsTheCheckout() throws {
		let manager = FileManager.default
		let project = RepoFiles.url("Machman.xcodeproj/project.pbxproj")
		#expect(manager.fileExists(atPath: project.path))
		#expect(manager.fileExists(atPath: RepoFiles.url("MachmanKit/Package.swift").path))
		let targets = try XcodeProject.load().targets.map(\.name)
		#expect(Set(targets) == Set(Self.apps.map(\.target)))
	}

	@Test("V6: the apps read Machman Desktop, Machman Agent and Machman VM, with (Dev) in Debug")
	func displayNames() throws {
		let project = try XcodeProject.load()
		for app in Self.apps {
			for configuration in Self.configurations {
				let name = project.resolved(
					"INFOPLIST_KEY_CFBundleDisplayName", target: app.target,
					configuration: configuration)
				let expected = app.name + (configuration == "Debug" ? " (Dev)" : "")
				#expect(name == expected, "\(app.target) \(configuration)")
				let product = project.resolved(
					"PRODUCT_NAME", target: app.target, configuration: configuration)
				#expect(product == app.target, "\(app.target) \(configuration) PRODUCT_NAME")
				// The user's rule: no product is ever named plain "Machman".
				for plain in ["Machman", "Machman (Dev)"] {
					#expect(name != plain && product != plain, "\(app.target) \(configuration)")
				}
			}
		}
	}

	@Test("W4-13: every app carries the copyright line")
	func copyright() throws {
		let project = try XcodeProject.load()
		for app in Self.apps {
			for configuration in Self.configurations {
				let place = "\(app.target) \(configuration)"
				#expect(project.resolved(
					"INFOPLIST_KEY_NSHumanReadableCopyright", target: app.target,
					configuration: configuration)
					== "Copyright © 2025 Gustaf Franzen. All rights reserved.", "\(place)")
				#expect(project.resolved(
					"GENERATE_INFOPLIST_FILE", target: app.target, configuration: configuration)
					== "YES", "\(place)")
				#expect(project.resolved(
					"INFOPLIST_FILE", target: app.target, configuration: configuration) == nil,
					"\(place): a hand-kept Info.plist would bypass the generated keys")
			}
		}
	}

	@Test("Q18: Debug builds use the .dev suite and Release the bare one")
	func bundleIdentifiers() throws {
		let project = try XcodeProject.load()
		for app in Self.apps {
			for configuration in Self.configurations {
				let suite = "com.gustaffranzen.Machman"
					+ (configuration == "Debug" ? ".dev" : "")
				#expect(project.resolved(
					"PRODUCT_BUNDLE_IDENTIFIER", target: app.target, configuration: configuration)
					== suite + app.idSuffix, "\(app.target) \(configuration)")
			}
		}
	}

	@Test("Q18: one app version, never below the daemon floor")
	func versionFloor() throws {
		let project = try XcodeProject.load()
		for app in Self.apps {
			for configuration in Self.configurations {
				let own = project.target(app.target)?.settings[configuration]?["MARKETING_VERSION"]
				#expect(own == nil, "\(app.target) \(configuration) sets its own MARKETING_VERSION")
			}
		}
		let debug = try #require(project.projectSettings["Debug"]?["MARKETING_VERSION"])
		let release = try #require(project.projectSettings["Release"]?["MARKETING_VERSION"])
		#expect(debug == release)
		let floor = try #require(try RepoFiles.daemonFloor())
		#expect(!MachmanVersion.isOlder(debug, than: floor),
			"MARKETING_VERSION \(debug) is below oldestCompatibleDaemonVersion \(floor)")
	}
}
