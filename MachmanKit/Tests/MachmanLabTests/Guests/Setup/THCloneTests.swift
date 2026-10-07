//
//  THCloneTests.swift
//  MachmanLabTests
//
//  L3 — duplicated guests: a copy of a configured VM serves the installer at its first boot,
//  shows no report of its source, and its run says it looks cloned, re-keys SSH under the
//  copy's own marker and keeps the user's own keys; each VM's VMInfo then tells its own
//  truth. And a fresh guest's first run reports SSH configured with a clean report.env.
//

import Foundation
import MachmanAPI
import Testing

enum THClones {
	/// A real key of the user's own in lab's authorized_keys (made in the guest).
	static func addUsersOwnKey(_ g: any THGuest, comment: String) async throws -> String {
		try await g.check(
			"rm -f /tmp/th-own && ssh-keygen -q -t ed25519 -N '' -C \(comment) -f /tmp/th-own"
				+ " </dev/null && mkdir -p -m 700 /home/lab/.ssh && cat /tmp/th-own.pub"
				+ " >> /home/lab/.ssh/authorized_keys && chown -R lab /home/lab/.ssh"
				+ " && chmod 600 /home/lab/.ssh/authorized_keys && cat /tmp/th-own.pub")
	}

	/// The copy of `source` (stopped by the guest itself), started, with root on its driver.
	static func copyAndBoot(_ source: THVZGuest, as name: String) async throws -> THVZGuest {
		try await source.powerOff()
		let copy = try await source.vm.copy(as: name)
		return try await source.sibling(copy)
	}

	/// The guest's IPv4 address (the source of its route out) once DHCP gave it one.
	static func address(_ g: THVZGuest) async throws -> String {
		try await LabStep.run("\(g.vm.name): waiting ≤60 s for a DHCP address") {
			let deadline = ContinuousClock.now + .seconds(60)
			while true {
				let address = try await g.check(
					"ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++)"
						+ " if ($i == \"src\") { print $(i + 1); exit } }'; true")
				if !address.isEmpty { return address }
				if ContinuousClock.now >= deadline {
					throw LabError.stateTimeout(
						vm: g.vm.name, wanted: "a DHCP address", last: "none")
				}
				try await Task.sleep(for: .seconds(2))
			}
		}
	}
}

// L3 — duplicated Debian guests and a fresh guest's first report.
@Suite("L3 Guest Setup — duplicates and first reports", .serialized, .enabled(if: Lab.runs(.l3)))
struct THCloneTests {
	@Test("G18: a duplicate says looks cloned, re-keys under its marker, keeps user keys")
	func duplicateRekeys() async throws {
		var options = THGuestOptions()
		options.name = "deb src"
		try await TH.withGuest(.debian, options) { g in
			let source = try #require(g as? THVZGuest)
			let own = try await THClones.addUsersOwnKey(g, comment: "me@laptop")
			let setUp = try await g.install(
				"-y --ssh --two-way", user: "lab", escalation: .sudo)
			#expect(setUp.status == 0, "\(setUp.output)")
			try await g.waitForReport(newerThan: nil)
			let sourceMarker = try g.marker()
			let copy = try await THClones.copyAndBoot(source, as: "deb src copy")
			do {
				// W2-34: the copy's first boot — no report yet, the installer in its share.
				let fresh = try await copy.vm.info()
				#expect(fresh.setup?.lastReportAt == nil, "\(String(describing: fresh.setup))")
				#expect(FileManager.default.fileExists(
					atPath: copy.vm.payloadDir + "/" + GuestSetupInstallerInfo.scriptName))
				#expect(try await copy.sh("test -f \(TH.installerPath)").status == 0)
				let started = try await g.reportMark()
				let run = try await copy.install(
					"-y --ssh --two-way", user: "lab", escalation: .sudo)
				#expect(run.status == 0, "\(run.output)")
				let said = TH.unwrapped(run.output)
				#expect(said.contains("looks cloned") && said.contains("treating it as new"),
					"\(run.output)")
				let copyMarker = try copy.marker()
				#expect(copyMarker != sourceMarker)
				let keys = try await copy.check("cat /home/lab/.ssh/authorized_keys")
					.split(separator: "\n").map(String.init)
				#expect(keys.filter { $0.contains(copyMarker) }.count == 1, "\(keys)")
				#expect(!keys.contains { $0.contains(sourceMarker) }, "\(keys)")
				#expect(keys.contains(own.trimmingCharacters(in: .whitespacesAndNewlines)),
					"the user's own key stays: \(keys)")
				try await copy.waitForReport(newerThan: started)
				let copyInfo = try await copy.vm.info()
				#expect(copyInfo.ssh?.configured == true)
				#expect(copyInfo.ssh?.guestUser == "lab")
				let sourceInfo = try await source.vm.info()
				#expect(sourceInfo.ssh?.configured == true)
				#expect(sourceInfo.ssh?.guestUser == "lab")
				await copy.shutdown()
			} catch {
				await copy.shutdown()
				throw error
			}
		}
	}

	@Test("W2-33: a duplicate made after a force quit shows no report of the source")
	func duplicateAfterForceQuit() async throws {
		var options = THGuestOptions()
		options.name = "deb fq"
		try await TH.withGuest(.debian, options) { g in
			let source = try #require(g as? THVZGuest)
			let setUp = try await g.install(
				"-y --ssh --two-way", user: "lab", escalation: .sudo)
			#expect(setUp.status == 0, "\(setUp.output)")
			try await g.waitForReport(newerThan: nil)
			try await g.check("sync")
			let sourceInfo = try await source.vm.info()
			try await source.vm.forceQuit()
			let copyVM = try await source.vm.copy(as: "deb fq copy")
			let copy = try await source.sibling(copyVM)
			do {
				// Before any run in the copy: nothing of the source's report shows.
				let deadline = ContinuousClock.now + .seconds(60)
				let address = try await copy.check(
					"ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++)"
						+ " if ($i == \"src\") { print $(i + 1); exit } }'")
				while ContinuousClock.now < deadline {
					let info = try await copy.vm.info()
					#expect(info.setup?.lastReportAt == nil, "\(String(describing: info.setup))")
					#expect(info.ssh?.guestHostname == nil, "\(String(describing: info.ssh))")
					if let shown = info.ssh?.address {
						// An address is the copy's own (DHCP may lease it the source's).
						#expect(shown == address || shown != sourceInfo.ssh?.address,
							"the copy shows the source's address \(shown)")
					}
					try await Task.sleep(for: .seconds(5))
				}
				await copy.shutdown()
			} catch {
				await copy.shutdown()
				throw error
			}
		}
	}

	@Test(
		"G19: a fresh guest's first run reports SSH configured and a clean report.env",
		arguments: [THGuestKind.debian, .alpine])
	func freshGuestReport(kind: THGuestKind) async throws {
		try await TH.withGuest(kind) { g in
			let started = try await g.reportMark()
			let run = try await g.install(
				"-y --ssh --two-way", user: "lab", escalation: kind.escalation)
			#expect(run.status == 0, "\(run.output)")
			let setup = try await g.waitForReport(newerThan: started)
			let ssh = setup.features?.first { $0.id == GuestFeature.ssh }
			#expect(ssh?.configured == true, "\(setup.features ?? [])")
			let info = try await g.vm.info()
			#expect(info.ssh?.configured == true)
			#expect(info.ssh?.guestUser == "lab")
			let report = try String(contentsOfFile: g.vm.reportFile, encoding: .utf8)
			// KEY=value lines (section keys carry the wire ids: FEATURE_reverseSSH=…) and
			// comments: nothing a tool printed on the way.
			let pattern = try NSRegularExpression(pattern: "^([A-Z][A-Za-z0-9_]*=|#)")
			for line in report.split(separator: "\n") {
				let text = String(line)
				let hit = pattern.firstMatch(
					in: text, range: NSRange(text.startIndex..., in: text))
				#expect(hit != nil, "a stray line in report.env: \(text)")
			}
		}
	}

	// S55: Duplicate gives the copy a new MAC, but its disk keeps /etc/machine-id, which
	// systemd-networkd derives its DHCP client id from, and the Mac's DHCP server keys its
	// leases on that id: the copy leased the source's address, and side by side the two
	// fought over it. The copy's Guest Setup run (its state is the source's, so it knows it
	// is a copy) gives it a machine id of its own, which its network takes up at the next
	// boot: a new client id, and with the source's lease still held, an address of its own.
	// (A lab copy shares its source's disk image, so the two never run at once.)
	@Test("S55: a duplicate's Guest Setup gives it a machine id, so it leases its own address")
	func duplicateLeasesItsOwnAddress() async throws {
		var options = THGuestOptions()
		options.name = "deb id"
		try await TH.withGuest(.debian, options) { g in
			let source = try #require(g as? THVZGuest)
			let setUp = try await g.install("-y --ssh --user lab")
			#expect(setUp.status == 0, "\(setUp.output)")
			let sourceID = try await g.check("cat /etc/machine-id")
			let sourceAddress = try await THClones.address(source)
			let copy = try await THClones.copyAndBoot(source, as: "deb id copy")
			do {
				let run = try await copy.install("-y --ssh --user lab")
				#expect(run.status == 0, "\(run.output)")
				#expect(THPlan(run.output)["identity"]?.contains("a new machine id") == true,
					"\(run.output)")
				let copyID = try await copy.check("cat /etc/machine-id")
				#expect(copyID.count == 32 && copyID != sourceID,
					"source \(sourceID), copy \(copyID)")
				try await copy.reboot()
				let copyAddress = try await THClones.address(copy)
				#expect(copyAddress != sourceAddress,
					"the copy leases its source's \(sourceAddress) (machine id \(copyID))")
				await copy.shutdown()
			} catch {
				await copy.shutdown()
				throw error
			}
		}
	}
}
