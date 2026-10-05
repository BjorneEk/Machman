//
//  TGGuest.swift
//  MachmanLabTests
//
//  The Alpine fixture as r3-tg's instrument, through its hvc0 shell: raw markers written to
//  and read from a virtio disk at a sector offset, the virtiofs share's subdirectories (one
//  per mount tag), a shell variable that tells one boot from another, and a power-off.
//  lab-init runs no mdev: the block and virtiofs drivers are loaded here (devtmpfs makes the
//  nodes). Every command string comes from a static builder, so the harness tier checks it.
//

import Foundation

struct TGGuest {
	let console: LabConsole

	/// The names a share always may carry beside the VM's own mounts.
	static let reservedShareNames: Set<String> = ["GuestSetup", "GuestReport"]

	// MARK: Command builders

	static func loadBlockDriverCommand(count: Int) -> String {
		"modprobe -q virtio_blk 2>/dev/null; i=0; "
			+ "while [ \"$(ls -d /sys/block/vd* 2>/dev/null | wc -l)\" -lt \(count) ] "
			+ "&& [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; "
			+ "ls -d /sys/block/vd* 2>/dev/null | wc -l"
	}

	static let disksCommand =
		"for d in /sys/block/vd*; do [ -e \"$d\" ] && echo \"${d##*/} $(cat $d/size)\"; done"

	static func writeMarkerCommand(_ text: String, device: String, sector: Int) -> String {
		"printf '%s' '\(text)' | dd of=\(device) bs=512 seek=\(sector) conv=notrunc,fsync "
			+ "2>/dev/null && sync"
	}

	static func readMarkerCommand(device: String, sector: Int, length: Int) -> String {
		"echo 3 > /proc/sys/vm/drop_caches; "
			+ "dd if=\(device) bs=512 skip=\(sector) count=1 2>/dev/null | head -c \(length) "
			+ "| tr -d '\\000'"
	}

	static let shareTagsCommand =
		"modprobe -q virtiofs 2>/dev/null; mkdir -p /mnt/s; "
			+ "mountpoint -q /mnt/s || mount -t virtiofs host-share /mnt/s; ls -1 /mnt/s"

	// MARK: Use

	/// Waits for lab-init's LAB-READY (a late connect sees it in the replay), then drains
	/// whatever else the socket replayed, so a marker of an earlier client never matches.
	static func ready(_ console: LabConsole, timeout: Duration = .seconds(60)) async throws
		-> TGGuest {
		try await console.expect("LAB-READY (\\S+)", timeout: timeout)
		let guest = TGGuest(console: console)
		try await guest.sync()
		return guest
	}

	/// A guest on a console a client used before: the replay drained by a fresh echo.
	static func attach(_ console: LabConsole) async throws -> TGGuest {
		let guest = TGGuest(console: console)
		try await guest.sync()
		return guest
	}

	func sync() async throws {
		let nonce = TG.nonce()
		// Split quoting: the echoed command line never matches the answer.
		try console.send("echo TG''SYNC-\(nonce)")
		try await console.expect("^TGSYNC-\(nonce)$", timeout: .seconds(30))
	}

	@discardableResult
	func run(_ command: String, timeout: Duration = .seconds(60)) async throws -> String {
		let result = try await console.run(command, timeout: timeout)
		guard result.status == 0 else {
			throw LabError.commandFailed(
				command: command, status: result.status, output: result.output)
		}
		return result.output
	}

	/// Loads virtio_blk and waits until `count` disks show; returns how many did.
	@discardableResult
	func loadBlockDriver(count: Int) async throws -> Int {
		Int(try await run(Self.loadBlockDriverCommand(count: count))) ?? 0
	}

	/// The guest's virtio disks: name → size in 512-byte sectors.
	func disks() async throws -> [String: Int] {
		var result: [String: Int] = [:]
		for line in try await run(Self.disksCommand).split(separator: "\n") {
			let parts = line.split(separator: " ")
			if parts.count == 2, let sectors = Int(parts[1]) { result[String(parts[0])] = sectors }
		}
		return result
	}

	/// The device of the disk with `sectors` sectors (each test gives its disks distinct sizes).
	func device(sectors: Int) async throws -> String {
		guard let name = try await disks().first(where: { $0.value == sectors })?.key else {
			throw LabError.specInvalid("the guest has no disk of \(sectors) sectors")
		}
		return "/dev/" + name
	}

	func writeMarker(_ text: String, device: String, sector: Int) async throws {
		try await run(Self.writeMarkerCommand(text, device: device, sector: sector))
	}

	func readMarker(device: String, sector: Int, length: Int) async throws -> String {
		try await run(Self.readMarkerCommand(device: device, sector: sector, length: length))
	}

	/// The virtiofs share's directories: one per mount tag, reserved names left out.
	func shareTags() async throws -> [String] {
		try await run(Self.shareTagsCommand).split(separator: "\n").map(String.init)
			.filter { !Self.reservedShareNames.contains($0) }.sorted()
	}

	func set(_ variable: String, _ value: String) async throws {
		try await run("export \(variable)='\(value)'")
	}

	func value(of variable: String) async throws -> String {
		try await run("echo \"${\(variable):-unset}\"")
	}

	/// Powers the guest off (VZ ends the run); no answer is awaited.
	func powerOff() throws { try console.send("poweroff -f") }

	/// Reboots the guest; under VZ a Linux guest's reboot ends the run too.
	func reboot() throws { try console.send("reboot -f") }
}
