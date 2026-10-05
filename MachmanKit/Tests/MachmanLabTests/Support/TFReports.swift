//
//  TFReports.swift
//  MachmanLabTests
//
//  A Guest Setup report as the script writes it (KEY=VALUE lines into the share's
//  GuestReport/report.env), for rows that need the engine to believe a guest ran the setup
//  without running it: the Alpine fixture writes it over virtiofs, the vmhost's poller
//  ingests it like a real one. Keys come from GuestReport's allowed set; no MARKER (a report
//  without one is accepted). Keys are made with ssh-keygen -f inside the sandbox only.
//

import Foundation
import MachmanTestSupport

struct TFReport: Sendable {
	var pairs: [(key: String, value: String)]

	init(_ pairs: [(String, String)]) { self.pairs = pairs.map { (key: $0.0, value: $0.1) } }

	func render() -> String { pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") }

	/// The keys a configured SSH guest reports: who it is, where, its host key, and a
	/// reverse key when it asks for access to the Mac.
	static func standard(
		user: String = "root", ip: String? = nil, hostKey: String? = nil, reverse: String? = nil
	) -> TFReport {
		var pairs: [(String, String)] = [
			("SCRIPT_VERSION", "6"), ("STATUS", "ok"), ("USER", user), ("OS_ID", "alpine"),
		]
		if let ip { pairs.append(("IP", ip)) }
		if let hostKey { pairs.append(("HOST_KEY", hostKey)) }
		if let reverse { pairs.append(("REVERSE_PUBKEY", reverse)) }
		return TFReport(pairs)
	}

	/// A fresh ed25519 key pair at `dir`/`name` (never outside the sandbox): the private key's
	/// path and the public key line.
	static func keyPair(in dir: String, name: String, comment: String = "tf") async throws
		-> (privatePath: String, publicLine: String) {
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let path = dir + "/" + name
		try? FileManager.default.removeItem(atPath: path)
		try? FileManager.default.removeItem(atPath: path + ".pub")
		let result = try await Subprocess.run(
			"/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", path],
			environment: ["PATH": "/usr/bin:/bin"])
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: "ssh-keygen -f \(path)", status: result.status, output: result.output)
		}
		let line = try String(contentsOfFile: path + ".pub", encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return (path, line)
	}
}
