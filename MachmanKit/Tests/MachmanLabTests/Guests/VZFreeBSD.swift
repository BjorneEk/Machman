//
//  VZFreeBSD.swift
//  MachmanLabTests
//
//  The vzfreebsd image (FreeBSD with the virtio-net and virtio-gpu work that boots under
//  Apple VZ) as a lab guest. Its tree is read-only to the lab: the image is built there by its
//  own `make image`, never by a test; scripts/lab/guests/vzfreebsd/import.sh clones
//  out/vzfreebsd.raw into the lab cache with a record of its source (git HEAD, FreeBSD pin).
//

import Foundation

enum VZFreeBSD {
	/// The source tree: MACHMAN_LAB_VZFREEBSD, else ~<account>/dev/2026/vzfreebsd (import.sh's
	/// default, from the account's home rather than $HOME).
	static var source: String {
		if let set = Lab.environment["MACHMAN_LAB_VZFREEBSD"], !set.isEmpty { return set }
		let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
		return (home ?? NSHomeDirectory()) + "/dev/2026/vzfreebsd"
	}

	static var sourceImageExists: Bool {
		FileManager.default.fileExists(atPath: source + "/out/vzfreebsd.raw")
	}

	/// import.sh's own sentence for a tree without an image.
	static var skipReason: String { "vzfreebsd image not built (make image in \(source))" }

	static var importer: String { LabScripts.lab + "/guests/vzfreebsd/import.sh" }

	/// The cached clone (re-imported when the source changed).
	static func importedPath() async throws -> String {
		LabScripts.lastLine(try await LabScripts.check(importer, ["path"], timeout: 900))
	}

	/// The import record (source, size, mtime, git HEAD and dirtiness, FreeBSD pin, sha256).
	static func record() async -> String {
		(try? await LabScripts.run(importer, ["status"]))?.output ?? "no import record"
	}
}
