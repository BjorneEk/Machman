//
//  TGHelperTests.swift
//  MachmanLabTests
//
//  Harness tier — r3-tg's helpers checked without an agent or a guest: config hand edits,
//  the guest command strings, the run-root listing.
//

import Foundation
import Testing
import MachmanTestSupport

@Suite("TG helpers", .enabled(if: Lab.runs(.harness)))
struct TGHelperTests {
	private func scratch() throws -> String {
		let dir = TestEnvironment.scratch + "tg-" + UUID().uuidString
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return dir
	}

	@Test("Q18: TG config edits keep every key they don't change")
	func configEditKeepsKeys() throws {
		let path = try scratch() + "/config"
		let original: [String: Any] = [
			"name": "tg", "lastRan": 781_234_567.25, "macAddress": "02:00:00:00:00:01",
			"startPolicy": ["windowed": false, "safe": false, "autostart": true],
			"disks": [["kind": ["storage": ["_0": "data", "_1": 67_108_864]], "safe": true]],
			"futureKey": ["nested": [1, 2, 3]],
		]
		try JSONSerialization.data(withJSONObject: original)
			.write(to: URL(fileURLWithPath: path))
		try TG.editConfig(atPath: path) { TG.setPolicy("safe", true, in: &$0) }
		let edited = try TG.config(atPath: path)
		let policy = try #require(edited["startPolicy"] as? [String: Any])
		#expect(policy["safe"] as? Bool == true)
		#expect(policy["autostart"] as? Bool == true)
		#expect(policy["windowed"] as? Bool == false)
		#expect(edited["lastRan"] as? Double == 781_234_567.25)
		#expect(edited["macAddress"] as? String == "02:00:00:00:00:01")
		#expect((edited["futureKey"] as? [String: Any])?["nested"] as? [Int] == [1, 2, 3])
		let disks = try #require(edited["disks"] as? [[String: Any]])
		let kind = disks.first?["kind"] as? [String: Any]
		#expect((kind?["storage"] as? [String: Any])?["_1"] as? Int == 67_108_864)
		#expect(Set(edited.keys) == Set(original.keys))
	}

	@Test("Q18: TG guest commands address the given sector and device")
	func guestCommands() {
		let write = TGGuest.writeMarkerCommand("TG1-abc234", device: "/dev/vdb", sector: 16)
		#expect(write == "printf '%s' 'TG1-abc234' | dd of=/dev/vdb bs=512 seek=16 "
			+ "conv=notrunc,fsync 2>/dev/null && sync")
		let read = TGGuest.readMarkerCommand(device: "/dev/vda", sector: 8, length: 10)
		#expect(read.contains("dd if=/dev/vda bs=512 skip=8 count=1"))
		#expect(read.contains("head -c 10"))
		#expect(read.hasPrefix("echo 3 > /proc/sys/vm/drop_caches; "))
		#expect(TGGuest.loadBlockDriverCommand(count: 2).contains("-lt 2 ]"))
		#expect(TGGuest.shareTagsCommand.contains("mount -t virtiofs host-share /mnt/s"))
		// The marker lands at sector × 512 on the host file.
		#expect(TGDisk(name: "data", mib: 64).sectors == 131_072)
	}

	@Test("Q18: TG run-dir listing sees only run-* entries")
	func runRootListing() throws {
		let dir = try scratch()
		for name in ["run-B", "run-A", "keep", ".run-hidden", "xrun-C"] {
			try FileManager.default.createDirectory(
				atPath: dir + "/" + name, withIntermediateDirectories: false)
		}
		#expect(TG.runRoots(in: dir) == [dir + "/run-A", dir + "/run-B"])
		#expect(TG.runRoots(in: dir + "/missing").isEmpty)
		let marker = dir + "/run-A/machman-shadow.json"
		try Data(#"{"vm":"tg-r1","createdAt":781234567,"pid":4242}"#.utf8)
			.write(to: URL(fileURLWithPath: marker))
		#expect(TG.marker(dir + "/run-A") == TG.Marker(vm: "tg-r1", pid: 4242))
		#expect(TG.marker(dir + "/run-B") == nil)
	}

	@Test("Q18: TG launchd helpers refuse a label or plist outside this run's suite")
	func launchdGuard() throws {
		let suite = "com.gustaffranzen.Machman.test-Ab12"
		let run = "/tmp/mml.Ab12"
		let plist = run + "/scopes/01/home/Library/LaunchAgents/\(suite).vm.tg.plist"
		#expect(throws: Never.self) {
			try TGLaunchd.check(label: suite + ".vm.tg", plist: plist, suite: suite, runDir: run)
		}
		// Another suite's job, the dev suite's, a bare suite label: refused.
		for label in [
			"com.gustaffranzen.Machman.test-Zz99.vm.tg", "com.gustaffranzen.Machman.dev.vm.tg",
			suite + ".vm.", suite + ".agent",
		] {
			#expect(throws: LabError.self) {
				try TGLaunchd.check(label: label, plist: nil, suite: suite, runDir: run)
			}
		}
		// A plist outside the run dir (the user's own LaunchAgents), or escaping it: refused.
		for path in [
			"/Users/lab/Library/LaunchAgents/\(suite).vm.tg.plist",
			run + "/../mml.Zz99/\(suite).vm.tg.plist", "/tmp/mml.Ab123/x.plist",
		] {
			#expect(throws: LabError.self) {
				try TGLaunchd.check(label: suite + ".vm.tg", plist: path, suite: suite, runDir: run)
			}
		}
		// No suite or no run dir: nothing passes.
		#expect(throws: LabError.self) {
			try TGLaunchd.check(label: ".vm.tg", plist: nil, suite: "", runDir: run)
		}
		#expect(throws: LabError.self) {
			try TGLaunchd.check(label: suite + ".vm.tg", plist: plist, suite: suite, runDir: "")
		}
	}
}
