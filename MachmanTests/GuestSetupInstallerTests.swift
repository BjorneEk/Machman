//
//  GuestSetupInstallerTests.swift
//  MachmanTests
//
//  The unified installer payload: the measured per-OS recipes survive assembly (launchctl
//  not systemsetup on macOS, sd_booted-style systemd detection, the openSUSE firewall
//  step, SELinux restorecon, the getty and bootloader matrices), every decision has a
//  flag, the report carries the v2 keys plus the v3 sections, and the payload writes what
//  a guest needs and nothing it must not see.
//
//  These assert on the script's TEXT, which is a blunt instrument — it catches a recipe
//  being dropped or renamed, not one being wrong. What the script actually does is
//  verified by running it in real guests (docs/local/manual-tests.md) and in the
//  container harness (docs/local/guest-cli-research).
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct GuestSetupInstallerTests {

	private var script: String { GuestSetupInstaller.script.text }

	@Test func scriptCarriesThePerOSSSHRecipes() {
		let s = script
		#expect(s.hasPrefix("#!/bin/sh"))
		// Parameterless by design: the marker and the host facts ride machman.env, so the
		// script text is the same bytes for every VM — and a copy taken out of the payload
		// says which file it is missing instead of failing obscurely.
		#expect(s.contains(#". "$PAYLOAD_DIR/machman.env""#))
		#expect(s.contains("is missing next to this script"))
		#expect(!s.contains("machman-abc123def456"))
		// macOS: launchctl path, never the TCC-gated systemsetup; host keys are minted at
		// first connection, so the script creates them itself.
		#expect(s.contains("launchctl enable system/com.openssh.sshd"))
		#expect(s.contains("/System/Library/LaunchDaemons/ssh.plist"))
		#expect(!s.contains("systemsetup -setremotelogin"))
		#expect(s.contains("ssh-keygen -A"))
		// One enable recipe per init system, so a non-systemd guest is never a dead end.
		#expect(s.contains("/run/systemd/system"))            // sd_booted, not `which systemctl`
		#expect(s.contains(#"systemctl enable --now "$SSHD_UNIT""#))
		#expect(s.contains("sysrc sshd_enable=YES"))          // FreeBSD
		#expect(s.contains("rcctl enable sshd"))              // OpenBSD
		#expect(s.contains("rc-update add sshd default"))     // OpenRC
		#expect(s.contains("ln -s /etc/sv/sshd /var/service/"))   // runit
		#expect(s.contains("update-rc.d"))                    // SysV
		#expect(s.contains("chkconfig"))
		// openSUSE firewall + SELinux fixup.
		#expect(s.contains("firewall-cmd --permanent --add-service=ssh"))
		#expect(s.contains("restorecon -R"))
		// NixOS: guided-declarative, with a backup + rebuild.
		#expect(s.contains("services.openssh.enable = true;"))
		#expect(s.contains("configuration.nix.machman-backup"))
		#expect(s.contains("nixos-rebuild switch"))
		// Package managers: probed, not guessed, with per-distro package names.
		for command in [
			"apt-get install -y", "dnf install -y", "yum install -y",
			"zypper --non-interactive install", "pacman -S --noconfirm", "apk add",
			"xbps-install -y", "emerge --quiet", "pkg install -y", "pkg_add",
		] {
			#expect(s.contains(command), "missing package-manager command \(command)")
		}
		#expect(s.contains("openssh-server"))
		#expect(s.contains("fuse-sshfs"))       // rhel-family sshfs
		#expect(s.contains("fusefs-sshfs"))     // FreeBSD sshfs
		#expect(s.contains("sshfs-fuse"))       // OpenBSD sshfs
	}

	// The console and bootloader matrices — the half the v1 console script never had.
	@Test func scriptCarriesTheConsoleAndBootloaderRecipes() {
		let s = script
		// Getty per mechanism: systemd unit, inittab line (+ HUP 1), runit service dir,
		// FreeBSD /etc/ttys, launchd plist. hvc0's generator-automatic case is recognized.
		#expect(s.contains("serial-getty@"))
		#expect(s.contains("::respawn:/sbin/getty 38400"))
		#expect(s.contains("kill -HUP 1"))
		#expect(s.contains(#""/usr/libexec/getty 3wire" vt100 onifexists secure"#))
		#expect(s.contains("com.machman.console-getty"))
		#expect(s.contains("/usr/libexec/getty"))
		#expect(s.contains("active-auto"))
		#expect(s.contains("kldload virtio_console"))
		#expect(s.contains("kld_list+=virtio_console"))
		// Guest device naming mirrors SerialPortKind.guestDevice.
		#expect(s.contains("cu.virtio"))
		#expect(s.contains(#"echo "ttyV$1.0""#))
		#expect(s.contains(#"echo "hvc$1""#))
		// Kernel console: grubby first (BLS), then the /etc/default/grub tools; sd-boot
		// and UKI report manual instead of blind edits; direct-kernel boots skip.
		#expect(s.contains("grubby --update-kernel=ALL --args="))
		#expect(s.contains("GRUB_CMDLINE_LINUX_DEFAULT"))
		#expect(s.contains("update-grub"))
		#expect(s.contains("grub-mkconfig"))
		#expect(s.contains("grub2-mkconfig"))
		#expect(s.contains("/boot/loader/entries"))
		#expect(s.contains("Machman owns"))
		// Automounts: one virtiofs fstab line; sshfs via fstab automounts on systemd and
		// boot scripts elsewhere; fstab space-escaping.
		#expect(s.contains("virtiofs rw,nofail 0 0"))
		#expect(s.contains("x-systemd.automount"))
		#expect(s.contains("fuse.sshfs"))
		#expect(s.contains(#"sed 's/ /\\040/g'"#))
		#expect(s.contains("/etc/local.d/machman-sshfs.start"))
		#expect(s.contains("/etc/rc.local"))
		// The connected-terminal rules: ssh sessions trust the client terminal.
		#expect(s.contains("SSH_TTY"))
		#expect(s.contains("SSH_CONNECTION"))
		#expect(!s.contains("|vt100)"))   // vt100 never implies colour
	}

	// The v2 contract: nothing is touched before the plan is shown, nothing fails without
	// a named step, and every question has a flag.
	@Test func scriptPreflightsAndExplainsFailures() {
		let s = script
		#expect(s.contains("PREFLIGHT_DONE"))
		#expect(s.contains("Dry run — nothing was changed."))
		#expect(s.contains("Proceed?"))
		#expect(s.contains("machman_exit_trap"))
		#expect(s.contains("trap on_exit EXIT"))
		#expect(s.contains("step_failed"))
		#expect(s.contains("valid_username"))
		// os-release is parsed, never sourced: it is guest-controlled and we are root.
		#expect(!s.contains(". /etc/os-release"))
		#expect(s.contains("sed -n \"s/^$1=//p\" /etc/os-release"))
		// A partial run still reports, with its own exit code — and the trap must not
		// clobber that report with a "failed" one.
		#expect(s.contains("exit 4"))
		#expect(s.contains("write_report failed"))
		#expect(s.contains("REPORT_DONE"))
	}

	@Test func scriptFlagsReportAndUninstall() {
		let s = script
		// Every decision the script can make has a flag, so it can run unattended.
		for flag in [
			"--console", "--no-console", "--consoles", "--kernel-console",
			"--no-kernel-console", "--ssh", "--no-ssh", "--two-way", "--one-way",
			"--sshfs", "--no-sshfs", "--automount-virtiofs", "--no-automount-virtiofs",
			"--automount-sshfs", "--no-automount-sshfs", "--mount-setup",
			"--no-mount-setup", "--mountpoint", "--install", "--no-install", "--pm",
			"--no-service", "--user", "--uninstall", "--yes", "--dry-run", "--verbose",
			"--quiet", "--help", "--version",
		] {
			#expect(s.contains(flag), "missing flag \(flag)")
		}
		// Root consoles (no sudo, no SUDO_USER) get a list of accounts, never a dead end.
		#expect(s.contains("USER_OVERRIDE"))
		#expect(s.contains("Which user should Machman set up SSH for?"))
		#expect(s.contains("candidate_users"))
		// Report keys the vmhost parser consumes: the v2 vocabulary verbatim, plus the v3
		// feature/console/automount/error sections and the state file.
		for key in [
			"SCRIPT_VERSION=", "MARKER=", "OS_ID=", "USER=", "HOME=", "HOSTNAME=",
			"IP=", "GATEWAY=", "TWO_WAY=", "HOST_KEY=", "REVERSE_PUBKEY=", "UNINSTALLED=1",
			"STATUS=", "FAILED_STEPS=", "NOTE=", "TRANSPORT=", "OS_FAMILY=", "OS_VERSION=",
			"INIT=", "SSHD=", "SSHFS=", "SSHFS_VERSION=", "SSHFS_MOUNT_OK=",
			"SSHFS_MOUNTROOT=", "FEATURE_", "CONSOLE_", "AUTOMOUNT_", "ERROR_",
			"KERNEL_CONSOLE=",
		] {
			#expect(s.contains(key), "missing report key \(key)")
		}
		// The wire feature ids match MachmanAPI's GuestFeature vocabulary.
		for id in [
			GuestFeature.console, GuestFeature.kernelConsole, GuestFeature.ssh,
			GuestFeature.reverseSSH, GuestFeature.sshfs, GuestFeature.virtiofsAutomount,
			GuestFeature.sshfsAutomount,
		] {
			#expect(s.contains("echo \(id)"), "missing wire feature id \(id)")
		}
		// State for reconfigure/repair: version-stamped, in the per-family dir.
		#expect(s.contains("/var/lib/machman"))
		#expect(s.contains("/var/db/machman"))
		#expect(s.contains("STATE_VERSION"))
		// Uninstall removes marker-matched artifacts but never disables sshd.
		#expect(s.contains(#"grep -vF "$MARKER""#))
		#expect(s.contains("--uninstall [--user <name>]"))
		// The report lands in the writable sibling, addressed payload-relatively (the
		// directory name itself comes from machman.env).
		#expect(s.contains(#"REPORT_DIR="$PAYLOAD_DIR/../$REPORT_DIR_NAME""#))
		// The script owns its version; Swift reads it back rather than declaring a twin.
		#expect(GuestSetupInstaller.script.version == 3)
		#expect(GuestSetupInstaller.scriptVersion == GuestSetupInstaller.script.version)
	}

	// sshfs plumbing vs permission: the fuse module rides along, vfs.usermount never does.
	@Test func scriptHandlesTheSshfsCapability() {
		let s = script
		#expect(s.contains("needs macFUSE"))
		#expect(s.contains("kldload fusefs"))
		#expect(s.contains("kld_list+=fusefs"))
		#expect(s.contains("vfs.usermount=1"))
		#expect(s.contains("/etc/sysctl.conf"))
		#expect(s.contains("Let ANY user of this guest mount filesystems"))
		#expect(s.contains(#"[ "$WANT_MOUNT_SETUP" = "1" ] || return 0"#))
		// OpenBSD dropped kern.usermount: say so instead of trying.
		#expect(s.contains("OpenBSD has no user mounts"))
	}

	@Test @MainActor func payloadWritesKeysScriptMountsAndReportDir() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "setuppay")
			let vm = try VMConfig(name: "setuppay", memorySize: 1 << 30, cpuCount: 2)
			try vm.addMountPoint(HostMountPoint(
				path: "/Users/x/My Docs", tag: "docs", kind: MountKind.sshfs))
			// Both dirs live under <vmdir>/share and nowhere else: that directory is what a
			// driverless guest sshfs-mounts, so it must never contain the disk images.
			let root = GuestInstallerWriter.payloadRoot(for: vm)
			let (payload, report) = try GuestSetupInstaller.writePayload(for: vm)
			#expect(payload.deletingLastPathComponent().path == root.path)
			#expect(report.deletingLastPathComponent().path == root.path)
			#expect(root.path.hasPrefix(vm.vmDirPath()))
			let fm = FileManager.default
			// Script 0755; machman.env sourced by it; the public key rides the payload.
			let scriptURL = payload.appendingPathComponent(GuestSetupInstaller.scriptName)
			let attrs = try fm.attributesOfItem(atPath: scriptURL.path)
			#expect((attrs[.posixPermissions] as? Int) == 0o755)
			let env = try String(
				contentsOf: payload.appendingPathComponent(
					GuestInstallerWriter.environmentFileName), encoding: .utf8)
			#expect(env.contains("HOST_USER="))
			#expect(env.contains("REPORT_DIR_NAME='GuestReport'"))
			#expect(env.contains("VM_NAME='setuppay'"))
			#expect(env.contains("BOOT_MODE='efi'"))
			#expect(env.contains("CONSOLE_COUNT='1'"))
			#expect(env.contains("SHARE_TAG='host-share'"))
			// The library is assembled INTO the script — no separate file to lose.
			#expect(!fm.fileExists(atPath: payload.appendingPathComponent(
				GuestInstallerWriter.sharedLibraryFileName).path))
			#expect(try String(contentsOf: scriptURL, encoding: .utf8)
				.contains("ui_detect()"))
			// The sshfs mounts ride mounts.list, tab-separated.
			let mounts = try String(
				contentsOf: payload.appendingPathComponent(
					GuestSetupInstallerInfo.mountsFileName), encoding: .utf8)
			#expect(mounts == "sshfs\tdocs\t/Users/x/My Docs\n")
			let pub = try String(
				contentsOf: payload.appendingPathComponent("host_key.pub"), encoding: .utf8)
			#expect(pub.hasPrefix("ssh-ed25519 "))
			// The private key never enters the payload — it stays under <vmdir>/ssh, 0600.
			#expect(!fm.fileExists(atPath: payload.appendingPathComponent("id_ed25519").path))
			let keyPath = vm.configFilePath(file: "ssh/id_ed25519")
			let keyAttrs = try fm.attributesOfItem(atPath: keyPath)
			#expect((keyAttrs[.posixPermissions] as? Int) == 0o600)
			// The marker is cached into config.ssh and is stable across writes.
			let first = vm.ssh?.marker
			#expect(first?.hasPrefix("machman-") == true)
			_ = try GuestSetupInstaller.writePayload(for: vm)
			#expect(vm.ssh?.marker == first)
			#expect(env.contains("MARKER='\(first ?? "!")'"))
			// A VM with no sshfs mounts ships no mounts.list at all.
			try vm.removeMountPoint(vm.mountPoints[0])
			let (bare, _) = try GuestSetupInstaller.writePayload(for: vm)
			#expect(!fm.fileExists(atPath: bare.appendingPathComponent(
				GuestSetupInstallerInfo.mountsFileName).path))
		}
	}

	// Attaching the installer writes its payload THERE AND THEN (a driverless guest
	// sshfs-mounts the directory from a running VM — empty is a dead end), and the two
	// pre-1.0.7 kinds map onto it instead of refusing.
	@Test @MainActor func attachingTheInstallerWritesThePayload() throws {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			let scriptPath = GuestInstallerWriter
				.payloadDirectory(named: GuestSetupInstallerInfo.directoryName, for: vm.config)
				.appendingPathComponent(GuestSetupInstallerInfo.scriptName).path
			let fm = FileManager.default
			#expect(!fm.fileExists(atPath: scriptPath))

			try api.attachDevice(.sshInstaller, to: vm)   // legacy kind maps to guestSetup
			#expect(fm.fileExists(atPath: scriptPath))
			#expect(vm.config.devices.contains { $0.deviceKind == .guestSetup })
			#expect(!vm.config.devices.contains { $0.deviceKind == .sshInstaller })
			// …and SSH counts as part of this VM from that moment, so its section appears
			// (a discovered address alone must never make that true).
			#expect(vm.config.ssh != nil)
		}
	}

	// The reserved share names — current AND superseded — are refused as user mount tags.
	@Test @MainActor func reservedShareNamesAreRefusedAsTags() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "setuptags")
			let vm = try VMConfig(name: "setuptags", memorySize: 1 << 30, cpuCount: 2)
			for reserved in ReservedShareNames.all {
				#expect(throws: MachmanError.self) {
					try vm.addMountPoint(HostMountPoint(path: "/tmp", tag: reserved))
				}
			}
		}
	}
}
