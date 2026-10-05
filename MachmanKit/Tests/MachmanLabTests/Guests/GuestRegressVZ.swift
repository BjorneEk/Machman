//
//  GuestRegressVZ.swift
//  MachmanLabTests
//
//  L3 — scripts/guest-regress under VZ (run.sh --backend vz runs this suite through lab.sh):
//  each suite inside a Machman VM of the lab agent, on a fresh clone of the prepared Debian
//  image. One VM per distro (one NAT address), its disks swapped per suite.
//
//  Driven only over the hvc2 console (T12: no host→guest TCP, so no Local Network prompt):
//  the staged payload comes in on a raw tar disk, each output goes back over the console, and
//  the script's own --evaluate rule reads it. Machman attaches its (here empty) host-share
//  device to every VM, which docker and QEMU guests lack: the payload copy at
//  /mnt/machman/share is bind-mounted onto itself, so it is a mountpoint as docker's volume
//  is and the script never mounts the empty share over it "now"; and where the automount
//  suite's `host-share /mnt/machman/share` fstab line mounted it at boot, the harness unmounts
//  it before the boot block (and says so in that output).
//
//  VZ NAT's gateway is this Mac, whose real sshd a suite's boot-time sshfs mount would reach:
//  before anything runs, the guest closes its own network (guest.sh lab-isolate: nothing but
//  DHCP leaves it, loaded again at every boot) — QEMU's restrict=on, from the inside.
//

import Foundation
import MachmanTestSupport
import Testing

enum GuestRegressVZ {
	/// hvc2: the lab's driver console in the prepared images (never a console under test).
	static let driverConsole = 2

	/// MACHMAN_LAB_REGRESS_DISTROS (set by scripts/guest-regress/run.sh --backend vz), else
	/// both Debian images.
	static var distros: [String] {
		let listed = words(Lab.environment["MACHMAN_LAB_REGRESS_DISTROS"])
		return listed.isEmpty ? [LabGuest.debian.rawValue, LabGuest.debianSysv.rawValue] : listed
	}

	/// MACHMAN_LAB_REGRESS_SUITES: only these suites of each distro (empty: all of them).
	static var suites: [String] { words(Lab.environment["MACHMAN_LAB_REGRESS_SUITES"]) }

	/// MACHMAN_LAB_REGRESS_RESULTS: a TSV the rows are appended to.
	static var resultsPath: String? {
		Lab.environment["MACHMAN_LAB_REGRESS_RESULTS"].flatMap { $0.isEmpty ? nil : $0 }
	}

	private static func words(_ value: String?) -> [String] {
		(value ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
	}

	static func run(distro: String, suites wanted: [String] = []) async throws
		-> [GuestRegress.Check] {
		guard let guest = LabGuest(rawValue: distro), guest.os == "debian" else {
			throw LabError.specInvalid("the VZ backend runs debian and debian-sysv, not \(distro)")
		}
		let table = try await GuestRegress.suites(for: distro)
		let chosen = wanted.isEmpty ? table : wanted
		if let stray = chosen.first(where: { !table.contains($0) }) {
			throw LabError.specInvalid("\(distro) does not run suite \(stray)")
		}
		let image = try await guest.imagePath()
		let work = Lab.runDir + "/regress-vz/\(distro)"
		let payload = try await stage(into: work)
		var checks: [GuestRegress.Check] = []
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(
				name: "rv-\(distro)", boot: .efiImagePath(image), cpus: 2, memoryGiB: 2,
				consolePorts: 3, network: true, extraDisks: [payload])
			try await agent.withVM(spec, start: false) { vm in
				for (index, suite) in chosen.enumerated() {
					if index > 0 { try await vm.replaceDisks(boot: image, extra: [payload]) }
					checks += try await runSuite(suite, distro: distro, on: vm, work: work)
				}
			}
		}
		if let path = resultsPath {
			let rows = checks.map {
				[$0.distro, $0.suite, $0.phase, $0.name, $0.status].joined(separator: "\t")
					+ "\n"
			}.joined()
			try append(rows, to: path)
		}
		return checks
	}

	/// <work>/in: the payload Machman would serve (staged by the script, as every backend
	/// does) and lab/isolate.sh; <work>/in.img: a raw tar of it, padded to whole MiB.
	static func stage(into work: String) async throws -> String {
		let manager = FileManager.default
		try? manager.removeItem(atPath: work)
		try manager.createDirectory(atPath: work + "/in/lab", withIntermediateDirectories: true)
		try await LabScripts.check(LabScripts.guestRegress, ["--stage", work + "/in"])
		let isolate = try await LabScripts.check(LabScripts.guest(os: "debian"), ["lab-isolate"])
		try isolate.write(toFile: work + "/in/lab/isolate.sh", atomically: true, encoding: .utf8)
		let image = work + "/in.img"
		let tar = try await Subprocess.run(
			"/usr/bin/tar",
			["--no-xattrs", "--no-mac-metadata", "-cf", image, "-C", work + "/in", "."],
			environment: ["COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"], timeout: 120)
		guard tar.status == 0 else {
			throw LabError.commandFailed(
				command: "tar \(image)", status: tar.status, output: tar.output)
		}
		let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: image))
		let size = try handle.seekToEnd()
		try handle.truncate(atOffset: (size / (1 << 20) + 1) << 20)
		try handle.close()
		return image
	}

	private static func runSuite(
		_ suite: String, distro: String, on vm: LabVM, work: String
	) async throws -> [GuestRegress.Check] {
		let started = ContinuousClock.now
		try await vm.start(timeout: .seconds(120))
		var console = try await login(vm, label: "\(suite)-run")
		try await prepare(console)
		let runOut = work + "/\(distro)-\(suite).run.out"
		try await runPhase(suite, distro: distro, phase: "run", console: console)
			.write(toFile: runOut, atomically: true, encoding: .utf8)
		var bootOut: String?
		if GuestRegress.hasBootChecks(suite) {
			try await powerOff(vm, console)
			try await vm.start(timeout: .seconds(120))
			console = try await login(vm, label: "\(suite)-boot")
			try await requireIsolated(console)
			let note = try await unshadowPayload(console)
			let path = work + "/\(distro)-\(suite).boot.out"
			let output = try await runPhase(suite, distro: distro, phase: "boot", console: console)
			try (note + output).write(toFile: path, atomically: true, encoding: .utf8)
			bootOut = path
		}
		try await powerOff(vm, console)
		LabScripts.log("guest-regress vz \(distro)/\(suite): \(ContinuousClock.now - started)")
		var checks = try await GuestRegress.evaluate(
			distro: distro, suite: suite, phase: "run", output: runOut)
		if let bootOut {
			checks += try await GuestRegress.evaluate(
				distro: distro, suite: suite, phase: "boot", output: bootOut)
		}
		return checks
	}

	private static func login(_ vm: LabVM, label: String) async throws -> LabConsole {
		try await vm.loggedInConsole(driverConsole, label: label)
	}

	@discardableResult
	private static func shell(
		_ console: LabConsole, _ command: String, timeout: Duration = .seconds(120)
	) async throws -> String {
		let result = try await console.run(command, timeout: timeout)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: command, status: result.status, output: result.output)
		}
		return result.output
	}

	/// The payload off its tar disk onto /mnt/machman/share (root-owned, as the QEMU backend
	/// untars it, and a mountpoint, as docker's volume is), after the guest closed its network.
	private static func prepare(_ console: LabConsole) async throws {
		let disk = try await shell(
			console,
			"for d in /dev/vd?; do dd if=$d bs=1 skip=257 count=5 2>/dev/null | grep -q ustar"
				+ " && echo $d; done")
		guard disk.hasPrefix("/dev/vd"), !disk.contains("\n") else {
			throw LabError.consoleUnavailable("no payload disk in the guest (\(disk))")
		}
		let inbox = "/var/lib/machman-lab/regress-in"
		try await shell(
			console,
			"rm -rf \(inbox) && mkdir -p \(inbox) && tar -xf \(disk) -C \(inbox) --no-same-owner")
		let isolated = try await shell(console, "sh \(inbox)/lab/isolate.sh")
		guard isolated.contains("lab-isolate: ok") else {
			throw LabError.commandFailed(command: "isolate.sh", status: 0, output: isolated)
		}
		try await requireIsolated(console)
		try await shell(
			console,
			"rm -rf /mnt/machman/share && mkdir -p /mnt/machman/share && (cd \(inbox)/payload"
				+ " && tar -cf - .) | tar -xf - -C /mnt/machman/share --no-same-owner"
				+ " && mount --bind /mnt/machman/share /mnt/machman/share")
	}

	/// The isolation must hold before a suite runs, and again after every boot.
	private static func requireIsolated(_ console: LabConsole) async throws {
		let table = try await console.run("nft list table inet machman_lab >/dev/null")
		guard table.status == 0 else {
			throw LabError.commandFailed(
				command: "nft list table inet machman_lab (the guest's network is open)",
				status: table.status, output: table.output)
		}
	}

	/// After a boot: a virtiofs share mounted over the payload copy (the automount suite's
	/// line) comes off again, so the boot block runs from the payload. Returns the note.
	private static func unshadowPayload(_ console: LabConsole) async throws -> String {
		let mounted = try await console.run("mountpoint -q /mnt/machman/share")
		guard mounted.status == 0 else { return "" }
		let source = try await shell(console, "findmnt -n -o SOURCE,FSTYPE /mnt/machman/share")
		try await shell(console, "umount /mnt/machman/share")
		return "lab: unmounted \(source) from /mnt/machman/share before the boot block\n"
	}

	/// One phase of a suite, detached from the console (no tty, stdin /dev/null — as over
	/// ssh); returns its output.
	private static func runPhase(
		_ suite: String, distro: String, phase: String, console: LabConsole
	) async throws -> String {
		let out = "/var/lib/machman-lab/regress/\(suite).\(phase).out"
		try await shell(
			console,
			"mkdir -p /var/lib/machman-lab/regress && REGRESS_DISTRO=\(distro) REGRESS_SHELL=sh"
				+ " REGRESS_BACKEND=vz REGRESS_PHASE=\(phase) setsid -w sh"
				+ " /mnt/machman/share/regress/\(suite).sh </dev/null >\(out) 2>&1; sync",
			timeout: .seconds(1200))
		return try await shell(console, "cat \(out)") + "\n"
	}

	private static func powerOff(_ vm: LabVM, _ console: LabConsole) async throws {
		try console.send("poweroff")
		try await vm.guestStopped(timeout: .seconds(180))
		console.close()
	}

	private static func append(_ text: String, to path: String) throws {
		let manager = FileManager.default
		if !manager.fileExists(atPath: path) { manager.createFile(atPath: path, contents: nil) }
		let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
		try handle.seekToEnd()
		try handle.write(contentsOf: Data(text.utf8))
		try handle.close()
	}
}

@Suite("L3 guest-regress under VZ", .serialized, .enabled(if: Lab.runs(.l3)))
struct GuestRegressVZTests {
	@Test(
		"R3W2-23: the guest-regress suites pass under VZ", arguments: GuestRegressVZ.distros)
	func suitesPassUnderVZ(distro: String) async throws {
		let checks = try await GuestRegress.run(
			.vz, distro: distro, suites: GuestRegressVZ.suites)
		#expect(!checks.isEmpty)
		for check in checks {
			#expect(check.passed, "\(check)")
		}
	}
}
