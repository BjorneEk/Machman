//
//  VZFreeBSD.swift
//  MachmanLabTests
//
//  The vzfreebsd image (FreeBSD with the virtio-net and virtio-gpu work that boots under
//  Apple VZ) as a lab guest: a copy kept in the lab cache by hand
//  (scripts/lab/guests/vzfreebsd/import.sh <image.raw>), nothing fetched or built. Its tests
//  run when the copy is there and skip, naming the import, when it isn't. Each run boots a
//  clone (LabFixtures.clone), never the cached file.
//

import Foundation

enum VZFreeBSD {
	/// <cache>/vzfreebsd/vzfreebsd.raw (import.sh's destination).
	static var imagePath: String { Lab.cacheDir + "/vzfreebsd/vzfreebsd.raw" }

	static var imageExists: Bool {
		!Lab.cacheDir.isEmpty && FileManager.default.fileExists(atPath: imagePath)
	}

	/// import.sh's own sentence for a cache without the image.
	static var skipReason: String {
		"vzfreebsd image missing (scripts/lab/guests/vzfreebsd/import.sh <image.raw> copies one"
			+ " to \(imagePath))"
	}

	static var importer: String { LabScripts.lab + "/guests/vzfreebsd/import.sh" }

	/// The import record (source, size, sha256, the image's manifest).
	static func record() async -> String {
		(try? await LabScripts.run(importer, ["status"]))?.output ?? "no import record"
	}
}
