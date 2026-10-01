//
//  VMCopierTests.swift
//  MachmanTests
//
//  VMCopier on bare temp directories — no VMTestDir lock (the copier takes explicit paths),
//  no Virtualization runtime. Source configs are written by hand-encoding VMConfig with the
//  persistence coder, never via saveVMConfig (which points at the global dir).
//

import Foundation
import MachmanTestSupport
import Testing
import Virtualization
import MachmanAPI
@testable import MachmanCore

struct VMCopierTests {
	private func makeLibrary() throws -> String {
		let dir = TestEnvironment.scratch + "vmcopier-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return dir
	}

	@discardableResult
	private func makeSourceVM(
		in library: String, name: String = "src",
		disks: [VMDisk] = [VMDisk(kind: .storage("disk", 0))],
		mounts: [HostMountPoint] = [],
		macAddress: String? = "aa:bb:cc:dd:ee:01",
		boot: BootConfig = .efi,
		extraFiles: [String: Data] = [:]
	) throws -> String {
		let dir = library + "/" + name
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"seed","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		config.name = name
		config.disks = disks
		config.mountPoints = mounts
		config.macAddress = macAddress
		config.boot = boot
		let encoder = JSONEncoder()
		try encoder.encode(config).write(to: URL(fileURLWithPath: dir + "/config"))
		for disk in disks {
			if case .storage(let diskName, _) = disk.kind {
				try Data("rawbytes-\(diskName)".utf8)
					.write(to: URL(fileURLWithPath: dir + "/\(diskName).raw"))
			}
		}
		for (file, data) in extraFiles {
			try data.write(to: URL(fileURLWithPath: dir + "/" + file))
		}
		return dir
	}

	// A bound UNIX socket file left behind, like a legacy <vm>/vm.sock (the fd closes, the
	// file stays).
	private func makeSocketFile(at path: String) throws {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		defer { close(fd) }
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		let bytes = Array(path.utf8)
		try #require(bytes.count < MemoryLayout.size(ofValue: addr.sun_path))
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
		let bound = withUnsafePointer(to: &addr) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		try #require(bound == 0)
	}

	private func loadConfig(_ dir: String) throws -> VMConfig {
		try JSONDecoder().decode(
			VMConfig.self, from: try Data(contentsOf: URL(fileURLWithPath: dir + "/config")))
	}

	// C15: whatever the caller checked, a copy never lands outside destinationParent.
	@Test func copyRefusesAPathAsTheNewName() throws {
		let library = try makeLibrary() + "/lib"
		try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
		let src = try makeSourceVM(in: library)
		for bad in ["../escape", "a/b", "..", "."] {
			let error = try #require(throws: MachmanError.self, "\(bad)") {
				try VMCopier.copy(VMCopyRequest(
					sourceDir: src, destinationParent: library, newName: bad))
			}
			#expect(error.code == .invalidArgument)
		}
		#expect(!FileManager.default.fileExists(atPath: library + "/../escape"))
	}

	@Test func clonedDiskIsIndependent() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/disk.raw"))
			== Data("rawbytes-disk".utf8))

		// Mutating the source afterwards must not touch the copy.
		try Data("changed".utf8).write(to: URL(fileURLWithPath: src + "/disk.raw"))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/disk.raw"))
			== Data("rawbytes-disk".utf8))
		let values = try URL(fileURLWithPath: dst + "/disk.raw")
			.resourceValues(forKeys: [.isExcludedFromBackupKey])
		#expect(values.isExcludedFromBackup == true)
	}

	@Test func referenceRewritesToTheSourceFile() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			diskPolicies: ["storage:disk": .reference]))
		let config = try loadConfig(dst)
		guard case .fromUrl(let url) = config.disks.first?.kind else {
			Issue.record("expected a fromUrl rewrite")
			return
		}
		#expect(url.path == src + "/disk.raw")
		#expect(!FileManager.default.fileExists(atPath: dst + "/disk.raw"))
	}

	@Test func omittedDiskLeavesNoTrace() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			diskPolicies: ["storage:disk": .omit]))
		#expect(try loadConfig(dst).disks.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: dst + "/disk.raw"))
	}

	@Test func macRegeneratedOnlyWhenAsked() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)

		let kept = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "kept",
			regenerateMAC: false))
		#expect(try loadConfig(kept).macAddress == "aa:bb:cc:dd:ee:01")

		let fresh = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "fresh",
			regenerateMAC: true))
		let mac = try #require(try loadConfig(fresh).macAddress)
		#expect(mac != "aa:bb:cc:dd:ee:01")
		#expect(VZMACAddress(string: mac) != nil)
	}

	@Test func identityAndSessionFilesDropped() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library, extraFiles: [
			"vm_identifier": Data("id".utf8),
			"restore.ipsw": Data("ipsw".utf8),
			"efi_vars.fd": Data("efi".utf8),
			"notes.txt": Data("notes".utf8),
		])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		let fm = FileManager.default
		#expect(!fm.fileExists(atPath: dst + "/vm_identifier"))
		#expect(!fm.fileExists(atPath: dst + "/restore.ipsw"))
		#expect(fm.fileExists(atPath: dst + "/efi_vars.fd"))
		#expect(fm.fileExists(atPath: dst + "/notes.txt"))
	}

	// C6: a volume without clonefile (exFAT, HFS+, a network share) used to get directory
	// sidecars as empty shells — kernels/ is user data — and a legacy vm.sock aborted the
	// whole copy on every volume. Both paths: the clone and the byte copy.
	@Test(arguments: [true, false])
	func directorySidecarsTravelWhole(allowClone: Bool) throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		let fm = FileManager.default
		try fm.createDirectory(
			atPath: src + "/kernels/kernel/v1", withIntermediateDirectories: true)
		try Data("kern".utf8).write(to: URL(fileURLWithPath: src + "/kernels/kernel/v1/vmlinuz"))
		try fm.createSymbolicLink(
			atPath: src + "/kernels/current", withDestinationPath: "kernel/v1/vmlinuz")
		try makeSocketFile(at: src + "/vm.sock")
		try makeSocketFile(at: src + "/kernels/s.sock")

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			allowClone: allowClone))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/kernels/kernel/v1/vmlinuz"))
			== Data("kern".utf8))
		#expect(try fm.destinationOfSymbolicLink(atPath: dst + "/kernels/current")
			== "kernel/v1/vmlinuz")
		#expect((try? fm.attributesOfItem(atPath: dst + "/vm.sock")) == nil)
		if !allowClone {
			#expect((try? fm.attributesOfItem(atPath: dst + "/kernels/s.sock")) == nil)
		}
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/disk.raw"))
			== Data("rawbytes-disk".utf8))
	}

	// The fallback's own engine: a byte copy (what every cross-volume import takes) lands
	// whole and reports progress to its total — the C callback used to trap.
	@Test func byteCopyLandsWholeWithProgress() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let bytes = Data(repeating: 0xAB, count: 512 * 1024)
		try bytes.write(to: URL(fileURLWithPath: library + "/big.img"))
		final class Reports: @unchecked Sendable {
			let lock = NSLock()
			var values: [(UInt64, UInt64)] = []
			func add(_ copied: UInt64, _ total: UInt64) {
				lock.lock()
				values.append((copied, total))
				lock.unlock()
			}
		}
		let reports = Reports()
		try FileTransfer.copy(
			src: library + "/big.img", dst: library + "/big.raw",
			progress: { reports.add($0, $1) }, allowClone: false)
		#expect(try Data(contentsOf: URL(fileURLWithPath: library + "/big.raw")) == bytes)
		#expect(reports.values.last?.0 == UInt64(bytes.count))
		#expect(reports.values.map(\.0) == reports.values.map(\.0).sorted())
	}

	// C9: serial session output is the source's; a fresh copy starts without it, a shadow
	// keeps it (the VM's own log, which an append-mode port continues).
	@Test func serialLogsStayWithTheSource() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let logs = ["serial-console0.log", "serial-uart1.log", "console.log"]
		var files = Dictionary(uniqueKeysWithValues: logs.map { ($0, Data("boot".utf8)) })
		files["serial-notes.log"] = Data("mine".utf8)
		let src = try makeSourceVM(in: library, extraFiles: files)
		let fm = FileManager.default

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		for log in logs {
			#expect(!fm.fileExists(atPath: dst + "/" + log), "\(log)")
		}
		#expect(fm.fileExists(atPath: dst + "/serial-notes.log"))   // not a port's log

		let shadow = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "shadow",
			regenerateMAC: false, identity: .impersonate))
		for log in logs {
			#expect(fm.fileExists(atPath: shadow + "/" + log), "\(log)")
		}
	}

	// C7: a crash leaves the guest share behind; its report is the source's and must not
	// become the copy's first-boot state. The share is per run — neither copy carries it.
	@Test func crashLeftoverShareStaysBehind() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		let report = src + "/" + GuestInstallerWriter.payloadRootName + "/"
			+ GuestSetupInstallerInfo.reportDirectoryName
		try FileManager.default.createDirectory(atPath: report, withIntermediateDirectories: true)
		try Data("MARKER=machman-src\nHOSTNAME=src-box\n".utf8)
			.write(to: URL(fileURLWithPath: report + "/" + GuestSetupInstallerInfo.reportName))

		for identity in [VMCopyRequest.Identity.fresh, .impersonate] {
			let dst = try VMCopier.copy(VMCopyRequest(
				sourceDir: src, destinationParent: library, newName: "dup-\(identity)",
				regenerateMAC: false, identity: identity))
			#expect(!FileManager.default.fileExists(
				atPath: dst + "/" + GuestInstallerWriter.payloadRootName))
		}
	}

	@Test func macOSGuestGetsAFreshMachineID() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let sourceID = VZMacMachineIdentifier().dataRepresentation
		let src = try makeSourceVM(in: library, extraFiles: [
			"mac_hardware_model": Data("model".utf8),
			"mac_aux.img": Data("aux".utf8),
			"mac_machine_id": sourceID,
		])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			guestKind: .macOS))
		let fm = FileManager.default
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/mac_hardware_model"))
			== Data("model".utf8))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/mac_aux.img"))
			== Data("aux".utf8))
		let newID = try Data(contentsOf: URL(fileURLWithPath: dst + "/mac_machine_id"))
		#expect(newID != sourceID)
		#expect(VZMacMachineIdentifier(dataRepresentation: newID) != nil)
		_ = fm
	}

	@Test func safeFlagsAndMountFilterCarried() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let keepMount = HostMountPoint(path: "/Users/x/keep", tag: "keep")
		let dropMount = HostMountPoint(path: "/Users/x/drop", tag: "drop")
		let src = try makeSourceVM(
			in: library,
			disks: [VMDisk(kind: .storage("disk", 0), safe: false)],
			mounts: [keepMount, dropMount])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			includedMountIDs: [keepMount.id.uuidString]))
		let config = try loadConfig(dst)
		#expect(config.disks.first?.safe == false)
		#expect(config.mountPoints.map(\.tag) == ["keep"])
	}

	@Test func existingDestinationRefused() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		try FileManager.default.createDirectory(
			atPath: library + "/dup", withIntermediateDirectories: true)

		#expect(throws: MachmanError.self) {
			try VMCopier.copy(VMCopyRequest(
				sourceDir: src, destinationParent: library, newName: "dup"))
		}
		// No staging residue either.
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: library)
			.filter { $0.hasPrefix(VMCopier.stagingPrefix) }
		#expect(leftovers.isEmpty)
	}

	@Test func copyResetsHistoryAndAutostart() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		let srcConfig = try loadConfig(src)
		srcConfig.lastRan = Date()
		srcConfig.totalRuntimeSeconds = 42
		srcConfig.startPolicy = StartPolicy(windowed: false, safe: false, autostart: true)
		try JSONEncoder().encode(srcConfig)
			.write(to: URL(fileURLWithPath: src + "/config"))

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		let config = try loadConfig(dst)
		#expect(config.name == "dup")
		#expect(config.lastRan == nil)
		#expect(config.totalRuntimeSeconds == 0)
		#expect(config.startPolicy.autostart == false)
		#expect(config.startPolicy.windowed == false)   // the rest of the policy carries
	}

	@Test func impersonateCarriesIdentityAndHistory() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let identifier = Data("vmid".utf8)
		let src = try makeSourceVM(in: library, extraFiles: ["vm_identifier": identifier])
		let srcConfig = try loadConfig(src)
		srcConfig.lastRan = Date(timeIntervalSinceReferenceDate: 5000)
		srcConfig.totalRuntimeSeconds = 42
		srcConfig.startPolicy.autostart = true
		try JSONEncoder().encode(srcConfig)
			.write(to: URL(fileURLWithPath: src + "/config"))

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "shadow",
			regenerateMAC: false, identity: .impersonate))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/vm_identifier"))
			== identifier)
		let config = try loadConfig(dst)
		#expect(config.created == srcConfig.created)
		#expect(config.lastRan == srcConfig.lastRan)
		#expect(config.totalRuntimeSeconds == 42)
		#expect(config.macAddress == "aa:bb:cc:dd:ee:01")
		#expect(config.startPolicy.autostart == false)   // cleared in BOTH identity modes
	}

	@Test func impersonateMacOSKeepsMachineID() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let sourceID = VZMacMachineIdentifier().dataRepresentation
		let src = try makeSourceVM(in: library, extraFiles: [
			"mac_hardware_model": Data("model".utf8),
			"mac_aux.img": Data("aux".utf8),
			"mac_machine_id": sourceID,
		])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "shadow",
			regenerateMAC: false, guestKind: .macOS, identity: .impersonate))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/mac_machine_id"))
			== sourceID)
	}

	@Test func safeFromUrlCloneRewritesToStorage() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let external = library + "/ubuntu-cloud.img"
		try Data("imgbytes".utf8).write(to: URL(fileURLWithPath: external))
		let disk = VMDisk(kind: .fromUrl(URL(fileURLWithPath: external)), safe: true)
		let src = try makeSourceVM(in: library, disks: [disk])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "shadow",
			diskPolicies: [disk.id: .clone], regenerateMAC: false, identity: .impersonate))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/ubuntu-cloud.raw"))
			== Data("imgbytes".utf8))
		let config = try loadConfig(dst)
		guard case .storage(let name, let size) = config.disks.first?.kind else {
			Issue.record("expected a storage rewrite")
			return
		}
		#expect(name == "ubuntu-cloud")
		#expect(size == 8)
		#expect(config.disks.first?.safe == true)
		// The user's external file is untouched, and the clone is VM-owned (backup-excluded).
		#expect(try Data(contentsOf: URL(fileURLWithPath: external)) == Data("imgbytes".utf8))
		let values = try URL(fileURLWithPath: dst + "/ubuntu-cloud.raw")
			.resourceValues(forKeys: [.isExcludedFromBackupKey])
		#expect(values.isExcludedFromBackup == true)
	}

	@Test func externalCloneNameCollisionUniquified() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let external = library + "/data.img"
		try Data("ext".utf8).write(to: URL(fileURLWithPath: external))
		let externalDisk = VMDisk(kind: .fromUrl(URL(fileURLWithPath: external)))
		let src = try makeSourceVM(
			in: library,
			disks: [VMDisk(kind: .storage("data", 0)), externalDisk])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			diskPolicies: [externalDisk.id: .clone]))
		let config = try loadConfig(dst)
		guard case .storage(let derived, _) = config.disks.last?.kind else {
			Issue.record("expected a storage rewrite")
			return
		}
		#expect(derived == "data-2")
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/data-2.raw"))
			== Data("ext".utf8))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/data.raw"))
			== Data("rawbytes-data".utf8))
	}

	@Test func inDirIsoEntryFollowsTheCopy() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(
			in: library,
			disks: [],   // set below once we know the dir
			extraFiles: ["cd.iso": Data("isodata".utf8)])
		let ownedIso = VMDisk(kind: .iso(URL(fileURLWithPath: src + "/cd.iso")))
		let externalIso = VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/outside.iso")))
		let config = try loadConfig(src)
		config.disks = [ownedIso, externalIso]
		try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: src + "/config"))

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		let copied = try loadConfig(dst)
		guard case .iso(let movedURL) = copied.disks[0].kind else {
			Issue.record("expected an iso entry")
			return
		}
		#expect(movedURL.path == dst + "/cd.iso")     // the entry followed the directory
		#expect(FileManager.default.fileExists(atPath: dst + "/cd.iso"))
		guard case .iso(let stayURL) = copied.disks[1].kind else {
			Issue.record("expected an iso entry")
			return
		}
		#expect(stayURL.path == "/isos/outside.iso")  // external references stay put
	}

	// C1: owned kernel paths embed the source directory; the copy must re-point them (both
	// the draft and the live boot payload) while external kernel paths stay put.
	@Test func ownedKernelPathsFollowTheCopy() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		try FileManager.default.createDirectory(
			atPath: src + "/kernels/kernel/v1", withIntermediateDirectories: true)
		try Data("kern".utf8)
			.write(to: URL(fileURLWithPath: src + "/kernels/kernel/v1/vmlinuz"))
		let settings = LinuxKernelBoot(
			kernelPath: src + "/kernels/kernel/v1/vmlinuz",
			initialRamdiskPath: "/outside/initrd.img", commandLine: "console=hvc0")
		let config = try loadConfig(src)
		config.kernelSettings = settings
		config.boot = .linuxKernel(settings)
		try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: src + "/config"))

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		let copied = try loadConfig(dst)
		#expect(copied.kernelSettings?.kernelPath == dst + "/kernels/kernel/v1/vmlinuz")
		#expect(copied.kernelSettings?.initialRamdiskPath == "/outside/initrd.img")
		guard case .linuxKernel(let live) = copied.boot else {
			Issue.record("expected a kernel boot")
			return
		}
		#expect(live.kernelPath == dst + "/kernels/kernel/v1/vmlinuz")
		#expect(FileManager.default.fileExists(atPath: dst + "/kernels/kernel/v1/vmlinuz"))
	}

	// The shadow flavor of the same rule: an impersonating copy points at ITS kernels, so a
	// later promotion only ever re-points within its own directory.
	@Test func shadowKernelPathsPointIntoTheShadow() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		try FileManager.default.createDirectory(
			atPath: src + "/kernels/initramfs/v1", withIntermediateDirectories: true)
		try Data("rd".utf8)
			.write(to: URL(fileURLWithPath: src + "/kernels/initramfs/v1/initrd.img"))
		let settings = LinuxKernelBoot(
			kernelPath: "/outside/vmlinuz",
			initialRamdiskPath: src + "/kernels/initramfs/v1/initrd.img", commandLine: "")
		let config = try loadConfig(src)
		config.kernelSettings = settings
		try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: src + "/config"))

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "shadow",
			regenerateMAC: false, identity: .impersonate))
		let copied = try loadConfig(dst)
		#expect(copied.kernelSettings?.kernelPath == "/outside/vmlinuz")
		#expect(copied.kernelSettings?.initialRamdiskPath
			== dst + "/kernels/initramfs/v1/initrd.img")
	}

	// C2/C3/C4/C8: a fresh copy resets the ssh INSTANCE identity (alias, lease, pin,
	// reverse grant, marker) while the user's switch and the disk-derived facts travel.
	@Test func freshCopyResetsSSHInstanceIdentity() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		try FileManager.default.createDirectory(
			atPath: src + "/ssh", withIntermediateDirectories: true)
		try Data("key".utf8).write(to: URL(fileURLWithPath: src + "/ssh/id_ed25519"))
		try Data("pin".utf8).write(to: URL(fileURLWithPath: src + "/ssh/known_hosts"))
		let config = try loadConfig(src)
		var ssh = SSHConfig()
		ssh.integrationEnabled = true
		ssh.guestUser = "gustaf"
		ssh.guestOS = "debian"
		ssh.guestHostname = "src-box"
		ssh.guestHostKey = "ssh-ed25519 AAAA src"
		ssh.lastAddress = "192.168.64.9"
		ssh.alias = "dev"
		ssh.reversePublicKey = "ssh-ed25519 BBBB guest"
		ssh.reverseState = SSHInfo.ReverseState.approved.rawValue
		ssh.marker = "machman-cafe"
		ssh.sshfsAvailable = true
		ssh.lastRunStatus = "ok"
		config.ssh = ssh
		try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: src + "/config"))

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		let copied = try #require(try loadConfig(dst).ssh)
		#expect(copied.alias == nil)
		#expect(copied.lastAddress == nil)
		#expect(copied.guestHostname == nil)
		#expect(copied.guestHostKey == nil)
		#expect(copied.reversePublicKey == nil)
		#expect(copied.reverseStateValue == .none)
		#expect(copied.marker == nil)
		#expect(copied.integrationEnabled == true)
		#expect(copied.guestUser == "gustaf")
		#expect(copied.guestOS == "debian")
		#expect(copied.sshfsAvailable == true)
		#expect(copied.lastRunStatus == "ok")
		// C14: the ssh dir stays behind — the pin is keyed to the source's alias, and the
		// keypair is the source's until the copy's first payload mints its own.
		#expect(!FileManager.default.fileExists(atPath: dst + "/ssh"))
	}

	// C14 / decision 12: a fresh copy serves the installer at its first boot — it forgets
	// the source's run (the guest will treat the clone as new) but keeps the OS facts. A
	// shadow IS the VM and keeps everything.
	@Test func freshCopyServesGuestSetupAgain() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		let config = try loadConfig(src)
		var setup = GuestSetupConfig()
		setup.installed = true
		setup.reinstallRequested = false
		setup.guestOS = "debian"
		setup.guestInit = "systemd"
		setup.scriptVersion = 4
		setup.lastRunStatus = "ok"
		setup.lastReportAt = Date(timeIntervalSince1970: 1_700_000_000)
		setup.features = [GuestFeatureInfo(id: GuestFeature.ssh, available: true, configured: true)]
		setup.consoles = [GuestConsoleInfo(device: "hvc0", login: "active")]
		config.setup = setup
		try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: src + "/config"))

		let copied = try loadConfig(try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup")))
		#expect(copied.servesSetupPayload)
		#expect(copied.setup?.installed == nil)
		#expect(copied.setup?.lastRunStatus == nil)
		#expect(copied.setup?.lastReportAt == nil)
		#expect(copied.setup?.scriptVersion == nil)
		#expect(copied.setup?.features.isEmpty == true)
		#expect(copied.setup?.consoles.isEmpty == true)
		#expect(copied.setup?.guestOS == "debian")
		#expect(copied.setup?.guestInit == "systemd")

		let shadow = try loadConfig(try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "shadow",
			regenerateMAC: false, identity: .impersonate)))
		#expect(shadow.setup == setup)
		#expect(!shadow.servesSetupPayload)
	}

	// The shadow IS the VM: its ssh state and pin travel verbatim.
	@Test func shadowCarriesSSHVerbatim() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		try FileManager.default.createDirectory(
			atPath: src + "/ssh", withIntermediateDirectories: true)
		try Data("pin".utf8).write(to: URL(fileURLWithPath: src + "/ssh/known_hosts"))
		let config = try loadConfig(src)
		var ssh = SSHConfig()
		ssh.integrationEnabled = true
		ssh.alias = "dev"
		ssh.lastAddress = "192.168.64.9"
		ssh.guestHostKey = "ssh-ed25519 AAAA src"
		ssh.reverseState = SSHInfo.ReverseState.approved.rawValue
		ssh.marker = "machman-cafe"
		config.ssh = ssh
		try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: src + "/config"))

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "shadow",
			regenerateMAC: false, identity: .impersonate))
		let copied = try #require(try loadConfig(dst).ssh)
		#expect(copied.alias == "dev")
		#expect(copied.lastAddress == "192.168.64.9")
		#expect(copied.guestHostKey == "ssh-ed25519 AAAA src")
		#expect(copied.reverseStateValue == .approved)
		#expect(copied.marker == "machman-cafe")
		#expect(FileManager.default.fileExists(atPath: dst + "/ssh/known_hosts"))
	}

	@Test func progressReportsMonotonicallyToTotal() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library, extraFiles: [
			"notes.txt": Data(repeating: 0xAB, count: 512 * 1024),
		])

		final class Reports: @unchecked Sendable {
			let lock = NSLock()
			var values: [(UInt64, UInt64)] = []
			func add(_ copied: UInt64, _ total: UInt64) {
				lock.lock()
				values.append((copied, total))
				lock.unlock()
			}
		}
		let reports = Reports()
		try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			progress: { reports.add($0, $1) }))

		let values = reports.values
		#expect(!values.isEmpty)
		#expect(values.map(\.0) == values.map(\.0).sorted())      // non-decreasing
		#expect(values.last?.0 == values.last?.1)                 // ends at total
	}
}
