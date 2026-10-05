//
//  XcodeProject.swift
//  MachmanTestSupport
//
//  Machman.xcodeproj's targets and build settings, read from project.pbxproj (an OpenStep
//  property list, which PropertyListSerialization reads) for lints: display names, bundle
//  ids, versions, sanitizers. `resolved` expands $(VAR) the way Xcode's lookup does for the
//  settings the project uses — the target's level, then the project's — and leaves an unknown
//  variable in place so a failing lint shows it.
//

import Foundation

public struct XcodeProject {
	public struct Target {
		public let name: String
		public let productType: String
		// Build settings by configuration name ("Debug", "Release"); arrays joined by spaces.
		public let settings: [String: [String: String]]
	}

	public let targets: [Target]
	public let projectSettings: [String: [String: String]]

	public static func load(
		_ url: URL = RepoFiles.url("Machman.xcodeproj/project.pbxproj")
	) throws -> XcodeProject {
		let data = try Data(contentsOf: url)
		guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
				as? [String: Any],
			let objects = plist["objects"] as? [String: [String: Any]],
			let rootID = plist["rootObject"] as? String,
			let project = objects[rootID]
		else {
			throw CocoaError(.propertyListReadCorrupt)
		}
		func settings(_ listID: Any?) -> [String: [String: String]] {
			guard let listID = listID as? String,
				let configurations = objects[listID]?["buildConfigurations"] as? [String]
			else { return [:] }
			var byName: [String: [String: String]] = [:]
			for id in configurations {
				guard let configuration = objects[id],
					let name = configuration["name"] as? String else { continue }
				let raw = configuration["buildSettings"] as? [String: Any] ?? [:]
				byName[name] = raw.mapValues { value in
					(value as? [String])?.joined(separator: " ") ?? "\(value)"
				}
			}
			return byName
		}
		let targets = (project["targets"] as? [String] ?? []).compactMap { id -> Target? in
			guard let target = objects[id], let name = target["name"] as? String else {
				return nil
			}
			return Target(
				name: name, productType: target["productType"] as? String ?? "",
				settings: settings(target["buildConfigurationList"]))
		}
		return XcodeProject(
			targets: targets, projectSettings: settings(project["buildConfigurationList"]))
	}

	public func target(_ name: String) -> Target? {
		targets.first { $0.name == name }
	}

	// The setting as Xcode resolves it for `target` in `configuration`: the target level,
	// else the project level, with $(VAR) and ${VAR} expanded through the same lookup (and
	// TARGET_NAME), at most 10 levels deep. nil when neither level sets it.
	public func resolved(_ key: String, target: String, configuration: String) -> String? {
		raw(key, target: target, configuration: configuration).map {
			expand($0, target: target, configuration: configuration, depth: 0)
		}
	}

	private func raw(_ key: String, target: String, configuration: String) -> String? {
		if key == "TARGET_NAME" { return target }
		return self.target(target)?.settings[configuration]?[key]
			?? projectSettings[configuration]?[key]
	}

	private static let variable = try! NSRegularExpression(
		pattern: #"\$\(([A-Za-z0-9_]+)\)|\$\{([A-Za-z0-9_]+)\}"#)

	private func expand(
		_ value: String, target: String, configuration: String, depth: Int
	) -> String {
		guard depth < 10 else { return value }
		var result = ""
		var cursor = value.startIndex
		let range = NSRange(value.startIndex..., in: value)
		for match in Self.variable.matches(in: value, range: range) {
			guard let whole = Range(match.range, in: value) else { continue }
			let nameRange = match.range(at: 1).location != NSNotFound
				? match.range(at: 1) : match.range(at: 2)
			guard let name = Range(nameRange, in: value).map({ String(value[$0]) }) else {
				continue
			}
			result += value[cursor..<whole.lowerBound]
			if let replacement = raw(name, target: target, configuration: configuration) {
				result += expand(
					replacement, target: target, configuration: configuration, depth: depth + 1)
			} else {
				result += value[whole]
			}
			cursor = whole.upperBound
		}
		result += value[cursor...]
		return result
	}
}
