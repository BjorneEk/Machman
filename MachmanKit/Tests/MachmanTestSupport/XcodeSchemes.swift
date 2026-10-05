//
//  XcodeSchemes.swift
//  MachmanTestSupport
//
//  The project's shared schemes (Machman.xcodeproj/xcshareddata/xcschemes) as XML documents,
//  for lints that query them with XPath: what a scheme tests, which sanitizers it runs.
//

import Foundation

public enum XcodeSchemes {
	public struct Scheme {
		public let name: String   // the file name without .xcscheme
		public let document: XMLDocument

		public init(name: String, data: Data) throws {
			self.name = name
			document = try XMLDocument(data: data)
		}

		public func nodes(_ xpath: String) -> [XMLNode] {
			(try? document.nodes(forXPath: xpath)) ?? []
		}
	}

	public static let directory = "Machman.xcodeproj/xcshareddata/xcschemes"

	// Every shared scheme, by name.
	public static func shared() throws -> [Scheme] {
		try RepoFiles.files(under: [directory], extension: "xcscheme").map { file in
			try Scheme(
				name: file.deletingPathExtension().lastPathComponent,
				data: Data(contentsOf: file))
		}
	}
}
