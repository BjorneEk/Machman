//
//  SSHSetupInstallerTests.swift
//  MachmanTests
//
//  The SSH setup payload: per-OS script content (the measured recipes — launchctl not
//  systemsetup on macOS, sd_booted-style systemd detection, the openSUSE firewall step,
//  SELinux restorecon), sh parseability, the marker/keypair/payload writes, and the
//  uninstall arm.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct SSHSetupInstallerTests {

	private var script: String {
		SSHSetupInstaller.script(vmName: "Debian", marker: "machman-abc123def456")
	}

	@Test func scriptCarriesThePerOSRecipes() {
		let s = script
		#expect(s.hasPrefix("#!/bin/sh"))
		#expect(s.contains(#"MARKER="machman-abc123def456""#))
		// macOS: launchctl path, never the TCC-gated systemsetup; host keys are minted at
		// first connection, so the script creates them itself.
		#expect(s.contains("launchctl enable system/com.openssh.sshd"))
		#expect(s.contains("launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist"))
		#expect(!s.contains("systemsetup -setremotelogin"))
		#expect(s.contains("ssh-keygen -A"))
		// FreeBSD + Alpine + systemd families.
		#expect(s.contains("sysrc sshd_enable=YES"))
		#expect(s.contains("rc-update add sshd default"))
		#expect(s.contains("/run/systemd/system"))
		#expect(s.contains(#"systemctl enable --now "$unit""#))
		// openSUSE firewall + SELinux fixup.
		#expect(s.contains("firewall-cmd --permanent --add-service=ssh"))
		#expect(s.contains("restorecon -R"))
		// NixOS: guided-declarative (skipped once sshd is active), terminator at column 0.
		#expect(s.contains("services.openssh.enable = true;"))
		#expect(s.contains("systemctl is-active sshd"))
		#expect(s.contains("\nNIXOS\n"))
		// Missing-sshd guidance + the opt-in installs.
		#expect(s.contains("apt-get install -y openssh-server"))
		#expect(s.contains("pacman -S --noconfirm openssh"))
		#expect(s.contains("dnf install -y openssh-server"))
		#expect(s.contains("zypper install -y openssh"))
		#expect(s.contains("apk add openssh"))
	}

	@Test func scriptFlagsReportAndUninstall() {
		let s = script
		for flag in ["--two-way", "--one-way", "--install", "--uninstall", "--user"] {
			#expect(s.contains(flag))
		}
		// Root consoles (no sudo, no SUDO_USER) get pointed at --user, never a dead end.
		#expect(s.contains("USER_OVERRIDE"))
		// Report keys the vmhost parser consumes.
		for key in [
			"SCRIPT_VERSION=", "MARKER=", "OS_ID=", "USER=", "HOME=", "HOSTNAME=",
			"IP=", "GATEWAY=", "TWO_WAY=", "HOST_KEY=", "REVERSE_PUBKEY=", "UNINSTALLED=1",
		] {
			#expect(s.contains(key), "missing report key \(key)")
		}
		// Uninstall removes marker-matched artifacts but never disables sshd.
		#expect(s.contains(#"grep -vF "$MARKER""#))
		#expect(s.contains("The SSH server itself was left"))
		// The report lands in the writable sibling, addressed payload-relatively.
		#expect(s.contains("/../SSHReport"))
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
			let (payload, report) = try SSHSetupInstaller.writePayload(for: vm)
			#expect(payload.path.hasPrefix(vm.vmDirPath()))
			#expect(report.path.hasPrefix(vm.vmDirPath()))
			let fm = FileManager.default
			// Script 0755; host.env sourced by it; the public key rides the payload.
			let scriptURL = payload.appendingPathComponent(SSHSetupInstaller.scriptName)
			let attrs = try fm.attributesOfItem(atPath: scriptURL.path)
			#expect((attrs[.posixPermissions] as? Int) == 0o755)
			let env = try String(
				contentsOf: payload.appendingPathComponent("host.env"), encoding: .utf8)
			#expect(env.contains("HOST_USER="))
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
			// The script embeds the same marker it cached.
			let body = try String(contentsOf: scriptURL, encoding: .utf8)
			#expect(body.contains(#"MARKER="\#(first ?? "!")""#))
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
