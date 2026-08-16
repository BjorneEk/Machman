//
//  SSHSetupInstallerTests.swift
//  MachmanTests
//
//  The SSH setup payload: per-OS script content (the measured recipes — launchctl not
//  systemsetup on macOS, sd_booted-style systemd detection, the openSUSE firewall step,
//  SELinux restorecon), the init/package-manager matrix, sh parseability, the
//  marker/keypair/payload writes, and the uninstall arm.
//
//  These assert on the script's TEXT, which is a blunt instrument — it catches a recipe
//  being dropped or renamed, not one being wrong. What the script actually does is
//  verified by running it in real guests (docs/local/manual-tests.md).
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct SSHSetupInstallerTests {

	private var script: String { SSHSetupInstaller.script.text }

	@Test func scriptCarriesThePerOSRecipes() {
		let s = script
		#expect(s.hasPrefix("#!/bin/sh"))
		// Parameterless by design: the marker and the host facts ride machman.env, so the
		// script text is the same bytes for every VM — and a copy taken out of the payload
		// says which file it is missing instead of failing obscurely.
		#expect(s.contains(#". "$PAYLOAD_DIR/machman.env""#))
		#expect(s.contains(#". "$PAYLOAD_DIR/machman-lib.sh""#))
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
		// NixOS: guided-declarative (skipped once sshd is active), --install edits the
		// config with a backup + rebuild.
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

	// The v2 contract: nothing is touched before the plan is shown, nothing fails without
	// a named step, and every question has a flag.
	@Test func scriptPreflightsAndExplainsFailures() {
		let s = script
		#expect(s.contains("preflight()"))
		#expect(s.contains("PREFLIGHT_DONE"))
		#expect(s.contains("Dry run — nothing was changed."))
		#expect(s.contains("Proceed?"))
		// Every mutation runs through the library's named-step wrappers, and the trap
		// turns any stray abort into a labeled one.
		#expect(s.contains("machman_exit_trap"))
		#expect(s.contains("trap on_exit EXIT"))
		#expect(s.contains("step_failed"))
		// The root-level injection the v1 script had (eval on a --user argument) is gone.
		#expect(!s.contains("eval echo"))
		#expect(s.contains("valid_username"))
		// os-release is parsed, never sourced: it is guest-controlled and we are root.
		#expect(!s.contains(". /etc/os-release"))
		#expect(s.contains("sed -n \"s/^$1=//p\" /etc/os-release"))
		// A partial run still reports, and says so with its own exit code.
		#expect(s.contains("exit 4"))
		#expect(s.contains("write_report failed"))
	}

	@Test func scriptFlagsReportAndUninstall() {
		let s = script
		// Every decision the script can make has a flag, so it can run unattended.
		for flag in [
			"--two-way", "--one-way", "--install", "--no-install", "--uninstall",
			"--user", "--pm", "--sshfs", "--no-sshfs", "--mount-setup", "--no-mount-setup",
			"--mountpoint", "--no-service", "--yes", "--dry-run", "--verbose", "--quiet",
			"--help", "--version",
		] {
			#expect(s.contains(flag), "missing flag \(flag)")
		}
		// Root consoles (no sudo, no SUDO_USER) get a list of accounts, never a dead end.
		#expect(s.contains("USER_OVERRIDE"))
		#expect(s.contains("Which user should Machman set up SSH for?"))
		#expect(s.contains("candidate_users"))
		// Report keys the vmhost parser consumes (v1 keys plus the 1.0.6 additions).
		for key in [
			"SCRIPT_VERSION=", "MARKER=", "OS_ID=", "USER=", "HOME=", "HOSTNAME=",
			"IP=", "GATEWAY=", "TWO_WAY=", "HOST_KEY=", "REVERSE_PUBKEY=", "UNINSTALLED=1",
			"STATUS=", "FAILED_STEPS=", "NOTE=", "TRANSPORT=", "OS_FAMILY=", "OS_VERSION=",
			"INIT=", "SSHD=", "SSHFS=", "SSHFS_VERSION=", "SSHFS_MOUNT_OK=",
			"SSHFS_MOUNTROOT=",
		] {
			#expect(s.contains(key), "missing report key \(key)")
		}
		// Uninstall removes marker-matched artifacts but never disables sshd; its usage
		// line advertises --user (root consoles need it for uninstall too).
		#expect(s.contains(#"grep -vF "$MARKER""#))
		#expect(s.contains("The SSH server itself was left"))
		#expect(s.contains("--uninstall [--user <name>]"))
		// The report lands in the writable sibling, addressed payload-relatively (the
		// directory name itself comes from machman.env).
		#expect(s.contains(#"REPORT_DIR="$PAYLOAD_DIR/../$REPORT_DIR_NAME""#))
		// The script owns its version; Swift reads it back rather than declaring a twin.
		#expect(SSHSetupInstaller.script.version == 2)
		#expect(SSHSetupInstaller.scriptVersion == SSHSetupInstaller.script.version)
	}

	// sshfs is offered only where it can work, and an already-installed one is a question
	// about reporting the capability, never about installing it again.
	@Test func scriptHandlesTheSshfsCapability() {
		let s = script
		#expect(s.contains("sshfs is already installed. Tell Machman"))
		#expect(s.contains("Install sshfs so this guest can mount host folders?"))
		#expect(s.contains("skipped — needs guest -> host SSH"))
		#expect(s.contains("needs macFUSE"))
		// FreeBSD's fuse knobs. Loading and persisting the driver is plumbing and rides
		// with sshfs; vfs.usermount is a system-wide permission, so it lives behind its
		// own explicit yes and is never implied by anything else.
		#expect(s.contains("kldload fusefs"))
		#expect(s.contains("kld_list+=fusefs"))
		#expect(s.contains("act_fuse_ready"))
		#expect(s.contains("vfs.usermount=1"))
		#expect(s.contains("/etc/sysctl.conf"))
		#expect(s.contains("Let ANY user of this guest mount filesystems"))
		#expect(s.contains(#"[ "$WANT_MOUNT_SETUP" = "1" ] || return 0"#))
		// OpenBSD dropped kern.usermount: say so instead of trying.
		#expect(s.contains("OpenBSD has no user mounts"))
	}

	// A quoting/heredoc slip would otherwise only surface inside a guest — parse the
	// generated script with the same interpreter the guest uses (sh -n: no execution).
	@Test func scriptParsesUnderSh() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("machman-ssh-setup-\(UUID().uuidString).sh")
		try script.write(to: url, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: url) }
		let sh = Process()
		sh.executableURL = URL(fileURLWithPath: "/bin/sh")
		sh.arguments = ["-n", url.path]
		try sh.run()
		sh.waitUntilExit()
		#expect(sh.terminationStatus == 0)
	}

	@Test @MainActor func payloadWritesKeysScriptAndReportDir() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshpay")
			let vm = try VMConfig(name: "sshpay", memorySize: 1 << 30, cpuCount: 2)
			// Both dirs live under <vmdir>/share and nowhere else: that directory is what a
			// driverless guest sshfs-mounts, so it must never contain the disk images.
			let root = GuestInstallerWriter.payloadRoot(for: vm)
			let (payload, report) = try SSHSetupInstaller.writePayload(for: vm)
			#expect(payload.deletingLastPathComponent().path == root.path)
			#expect(report.deletingLastPathComponent().path == root.path)
			#expect(root.path.hasPrefix(vm.vmDirPath()))
			let fm = FileManager.default
			// Script 0755; machman.env sourced by it; the public key rides the payload.
			let scriptURL = payload.appendingPathComponent(SSHSetupInstaller.scriptName)
			let attrs = try fm.attributesOfItem(atPath: scriptURL.path)
			#expect((attrs[.posixPermissions] as? Int) == 0o755)
			let env = try String(
				contentsOf: payload.appendingPathComponent(
					GuestInstallerWriter.environmentFileName), encoding: .utf8)
			#expect(env.contains("HOST_USER="))
			#expect(env.contains("REPORT_DIR_NAME='SSHReport'"))
			#expect(env.contains("VM_NAME='sshpay'"))
			// The helpers the script sources ride along, or it dies on the first line.
			let lib = payload.appendingPathComponent(
				GuestInstallerWriter.sharedLibraryFileName)
			#expect(try String(contentsOf: lib, encoding: .utf8).contains("ui_detect()"))
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
			_ = try SSHSetupInstaller.writePayload(for: vm)
			#expect(vm.ssh?.marker == first)
			// The env carries the same marker the config cached.
			#expect(env.contains("MARKER='\(first ?? "!")'"))
		}
	}

	// The reserved share names are refused as user mount tags (add AND rename).
	@Test @MainActor func reservedShareNamesAreRefusedAsTags() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshtags")
			let vm = try VMConfig(name: "sshtags", memorySize: 1 << 30, cpuCount: 2)
			for reserved in [SSHSetupInfo.directoryName, SSHSetupInfo.reportDirectoryName] {
				#expect(throws: MachmanError.self) {
					try vm.addMountPoint(HostMountPoint(path: "/tmp", tag: reserved))
				}
			}
		}
	}
}
