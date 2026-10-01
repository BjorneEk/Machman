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
//  container harness (scripts/guest-regress).
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
		#expect(s.contains("rc_conf_yes sshd"))               // NetBSD (rc.conf, no sysrc)
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
			"xbps-install -y", "emerge --quiet", "pkg install -y", "pkgin -y install",
			"pkg_add",
		] {
			#expect(s.contains(command), "missing package-manager command \(command)")
		}
		#expect(s.contains("openssh-server"))
		#expect(s.contains("fuse-sshfs"))       // rhel-family sshfs
		#expect(s.contains("fusefs-sshfs"))     // FreeBSD sshfs
		#expect(s.contains("sshfs-fuse"))       // OpenBSD sshfs (pkgsrc: fuse-sshfs)
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
		#expect(s.contains(#""/usr/libexec/getty default" vt100 on secure"#))   // NetBSD
		#expect(s.contains("com.machman.console-getty"))
		#expect(s.contains("/usr/libexec/getty"))
		#expect(s.contains("active-auto"))
		#expect(s.contains("kldload virtio_console"))
		#expect(s.contains("kld_list+=virtio_console"))
		// Guest device naming mirrors SerialPortKind.guestDevice.
		#expect(s.contains("cu.virtio"))
		#expect(s.contains(#"echo "ttyV$1.0""#))
		#expect(s.contains(#"echo "ttyVI${1}0""#))   // NetBSD viocon(4)
		#expect(s.contains(#"echo "hvc$1""#))
		// Kernel console: FLAG-ONLY (it edits the boot loader — the usage text warns and
		// the menu never offers it), always keeps the display on tty0, backs up grub.cfg,
		// and reports a pending state until the reboot makes it active.
		#expect(s.contains("EDITS THE BOOT LOADER"))
		#expect(s.contains("console=tty0"))
		#expect(s.contains("grub.cfg.machman-backup"))
		#expect(s.contains("kernel-next"))
		#expect(s.contains("pending reboot"))
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
		// Source and mountpoint travel as TWO results — host paths carry spaces (the
		// share lives under "Application Support"), so a packed pair split on the first
		// space truncated every such source.
		#expect(s.contains("R_MOUNT_WHAT"))
		#expect(s.contains("R_MOUNT_WHERE"))
		#expect(!s.contains(#"${R_ITEM%% *}"#))
		// nofail/_netdev are fstab words — a raw sshfs command hands them to libfuse,
		// which refuses the whole mount (measured). They live on the fstab line only;
		// boot scripts embed the absolute sshfs path (FreeBSD's rc PATH lacks
		// /usr/local/bin) and BatchMode so a refused key fails fast, never prompts.
		#expect(s.contains("noauto,x-systemd.automount,nofail,_netdev,"))
		#expect(s.contains("BatchMode=yes"))
		#expect(!s.contains("ServerAliveCountMax=3,nofail"))
		#expect(s.contains(#"command -v sshfs"#))
		// The connected-terminal rules: a pseudo-terminal trusts the client terminal —
		// keyed on the tty NAME, which survives doas/sudo stripping LANG and SSH_*.
		#expect(s.contains("/dev/pts/"))
		#expect(s.contains("/dev/ttyp"))
		#expect(!s.contains("SSH_TTY"))   // env-based detection dies under doas/sudo
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
			"--quiet", "--help", "--version", "--report-only", "--at-boot",
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
			"SSHFS_MOUNTROOT=", "FEATURE_", "CONSOLE_", "AUTOMOUNT_", "ERROR_", "NOTE_",
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
		// Ownership-aware verbs: foreign artifacts are adopted (restorably) or reported,
		// never touched blind; a different key owner becomes an explicit switch.
		#expect(s.contains("-superseded"))
		#expect(s.contains("restore_superseded"))
		#expect(s.contains("configured outside Machman"))
		#expect(s.contains("Move SSH from"))
		#expect(s.contains("left as is"))
		#expect(s.contains("(external)"))
		// Uninstall removes marker-matched artifacts but never disables sshd, and every
		// edit goes through the link-safe helpers: no fixed temp name is left to plant.
		#expect(s.contains(#"drop_lines "$_su_ak" "$MARKER""#))
		#expect(!s.contains(".machman-tmp"))
		#expect(s.contains("--uninstall [--user <name>]"))
		// The report lands in the writable sibling, addressed payload-relatively (the
		// directory name itself comes from machman.env) — or, for the boot-time copy, where
		// its own machman.env says.
		#expect(s.contains(#"REPORT_DIR="${BOOT_REPORT_DIR:-$PAYLOAD_DIR/../$REPORT_DIR_NAME}""#))
		// The script owns its version; Swift reads it back rather than declaring a twin.
		#expect(GuestSetupInstaller.script.version == 4)
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

	// --report-only + the boot hook: promised states ("configured", "pending reboot")
	// flip to reality once the guest reboots, without a manual re-run.
	@Test func scriptRefreshesTheReportAtBoot() {
		let s = script
		#expect(s.contains("--report-only"))
		#expect(s.contains("machman-report.service"))
		#expect(s.contains("ConditionPathExists="))
		#expect(s.contains("/etc/local.d/machman-report.start"))
		#expect(s.contains("com.machman.report"))
		// FreeBSD rides its own rc.d script, ordered AFTER /etc/rc.local (the sshfs
		// mounts) — never an rc.local line, whose marker block strip would clobber it.
		#expect(s.contains("/usr/local/etc/rc.d/machman_report"))
		#expect(s.contains("REQUIRE: local"))
		// A probe run describes the LAST real run's outcome, not its own.
		#expect(s.contains(#"_wr_status="${ST_LAST_STATUS:-ok}""#))
		#expect(s.contains("refreshed Machman's report"))
		// S27/S12: every hook runs the guest's own copy beside the state, never the share
		// (unserved once installed, elsewhere on macOS), so no payload dir name is baked in.
		#expect(s.contains(#"REPORT_COPY="$STATE_DIR/report.sh""#))
		#expect(!s.contains("/GuestSetup/"))
	}

	// S27: macOS guests mount the share at "My Shared Files", not the Linux share root.
	@Test @MainActor func macOSGuestsGetTheirShareRoot() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sharemac")
			let vm = try VMConfig(name: "sharemac", memorySize: 1 << 30, cpuCount: 2)
			#expect(try GuestSetupInstaller.environment(for: vm)["SHARE_ROOT"] == GuestPaths.share)
			vm.boot = .macOS(MacOSBoot(
				installState: .installed, minimumCPUCount: 2, minimumMemorySize: 1 << 30))
			#expect(try GuestSetupInstaller.environment(for: vm)["SHARE_ROOT"]
				== GuestPaths.macOSAutomount)
		}
	}

	// A cloned guest disk (and a copied VM directory) carries the SOURCE's marker on
	// every machman artifact; each layer treats that as stale and replaces it.
	@Test func scriptHandlesClonedGuests() {
		let s = script
		#expect(s.contains("removed another Machman VM's key (cloned guest)"))
		#expect(s.contains("replaced another Machman VM's guest key (cloned guest)"))
		#expect(s.contains("treating it as new"))
		// Host-key generation chatter goes to stdout — inside write_report's
		// redirection that would land in report.env.
		#expect(s.contains("ssh-keygen -A >/dev/null 2>&1"))
	}

	@Test @MainActor func copiedKeypairIsReminted() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "clonekey")
			let vm = try VMConfig(name: "clonekey", memorySize: 1 << 30, cpuCount: 2)
			let first = try SSHSetupInstaller.ensureKeypair(
				for: vm, marker: "machman-aaaa11112222")
			#expect(first.contains("machman-aaaa11112222"))
			// Same marker: the key is stable across payload writes.
			let again = try SSHSetupInstaller.ensureKeypair(
				for: vm, marker: "machman-aaaa11112222")
			#expect(again == first)
			// A different marker means the key came from another VM's directory (a
			// copy): it is re-minted under the new identity.
			let reminted = try SSHSetupInstaller.ensureKeypair(
				for: vm, marker: "machman-bbbb33334444")
			#expect(reminted.contains("machman-bbbb33334444"))
			#expect(reminted != first)
		}
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

	// Payloads are ephemeral (1.0.7): attach on a STOPPED VM defers to the next start —
	// the eager write exists only for attach-on-a-running-VM (the sshfs bootstrap). The
	// two pre-1.0.7 kinds map onto guestSetup instead of refusing, and removePayload
	// Every virtiofs mount rides the ONE automounted share (its tag subdirectory);
	// sshfs mounts match their own automount record by tag. The served automountedAt
	// carries the guest directory either way.
	@Test @MainActor func servedMountsSayWhereTheyAutomount() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "automounts")
			let config = try VMConfig(name: "automounts", memorySize: 1 << 30, cpuCount: 2)
			try config.addMountPoint(HostMountPoint(
				path: "/Users/x/Media", tag: "media", kind: MountKind.virtiofs))
			try config.addMountPoint(HostMountPoint(
				path: "/Users/x/My Docs", tag: "docs", kind: MountKind.sshfs))
			try config.addMountPoint(HostMountPoint(
				path: "/Users/x/Other", tag: "other", kind: MountKind.sshfs))
			var state = GuestSetupConfig()
			state.installed = true
			state.automounts = [
				GuestAutomountInfo(
					kind: MountKind.virtiofs, target: "host-share",
					path: "/mnt/machman/share"),
				GuestAutomountInfo(
					kind: MountKind.sshfs, target: "docs",
					path: "/mnt/machman/mounts/docs"),
			]
			config.setup = state

			let mounts = LocalMachman.mountInfos(for: config)
			let media = try #require(mounts.first { $0.tag == "media" })
			#expect(media.automounted == true)
			#expect(media.automountedAt == "/mnt/machman/share/media")
			let docs = try #require(mounts.first { $0.tag == "docs" })
			#expect(docs.automounted == true)
			#expect(docs.automountedAt == "/mnt/machman/mounts/docs")
			// No record for this one: not automounted, no claimed directory.
			let other = try #require(mounts.first { $0.tag == "other" })
			#expect(other.automounted == nil)
			#expect(other.automountedAt == nil)
		}
	}

	// Serving is a question of CONTENT: the two reserved dirs are registered whatever
	// the state, so a non-serving start mounts an empty pair and toggling on later
	// fills in place with no device changes.
	@Test @MainActor func nonServingStartsMountEmptyDirectories() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "serving")
			let vm = try VMConfig(name: "serving", memorySize: 1 << 30, cpuCount: 2)
			let fm = FileManager.default

			// Installed guest, no reinstall requested: dirs exist, both EMPTY.
			var state = GuestSetupConfig()
			state.installed = true
			vm.setup = state
			#expect(!vm.servesSetupPayload)
			let (payload, report) = try GuestSetupInstaller.ensurePayloadDirectories(for: vm)
			#expect(fm.fileExists(atPath: payload.path))
			#expect(fm.fileExists(atPath: report.path))
			#expect(try fm.contentsOfDirectory(atPath: payload.path).isEmpty)

			// The reinstall request flips the rule, and the fill lands in place.
			vm.setup?.reinstallRequested = true
			#expect(vm.servesSetupPayload)
			_ = try GuestSetupInstaller.writePayload(for: vm)
			#expect(fm.fileExists(
				atPath: payload.appendingPathComponent(
					GuestSetupInstallerInfo.scriptName).path))
		}
	}

	// clears the current AND superseded directory names.
	@Test @MainActor func payloadsAreEphemeral() throws {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			let scriptPath = GuestInstallerWriter
				.payloadDirectory(named: GuestSetupInstallerInfo.directoryName, for: vm.config)
				.appendingPathComponent(GuestSetupInstallerInfo.scriptName).path
			let fm = FileManager.default

			try api.attachDevice(.sshInstaller, to: vm)   // legacy kind maps to guestSetup
			#expect(vm.config.devices.contains { $0.deviceKind == .guestSetup })
			#expect(!vm.config.devices.contains { $0.deviceKind == .sshInstaller })
			// Stopped: nothing written yet — the payload appears at the next assembly.
			#expect(!fm.fileExists(atPath: scriptPath))

			// The start-time write (assembly calls this): everything appears…
			_ = try GuestSetupInstaller.writePayload(for: vm.config)
			#expect(fm.fileExists(atPath: scriptPath))
			#expect(vm.config.ssh != nil)   // marker cached: SSH is part of this VM now
			// …and a stale superseded dir from an older build is cleaned with it.
			let legacy = GuestInstallerWriter.payloadDirectory(
				named: SSHSetupInfo.directoryName, for: vm.config)
			try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
			_ = try GuestSetupInstaller.writePayload(for: vm.config)
			#expect(!fm.fileExists(atPath: legacy.path))

			// Teardown/sweep call this: the served dirs go, and the emptied share root
			// goes with them (D10 — the next assembly recreates it).
			GuestSetupInstaller.removePayload(for: vm.config)
			#expect(!fm.fileExists(atPath: scriptPath))
			#expect(!fm.fileExists(atPath: GuestInstallerWriter.payloadRoot(for: vm.config).path))
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
