//
//  GuestScriptSshfsTests.swift
//  MachmanTests
//
//  The sshfs features' system edits (55-sshfs, 65-automount-sshfs), run for real under every
//  local POSIX shell through GuestScriptHarness: the files they keep go through the lib's
//  write_file/put_block like every other, and they say "ready" only when it is. System
//  paths point into the probe's scratch dir; sysctl, kldload and rc-update are stand-ins.
//  UI_COLS=1000: the script folds what it says at the terminal's width; these read it whole.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptSshfsTests {

	// MARK: - Kept system files (S43)

	// S43: the allowed user mount is kept in a block tagged <marker>-usermount (the uninstall
	// names it), written once, through the lib: a sysctl.conf that is a link is refused by
	// name and its target untouched; a file already setting it, and a dry run, write nothing.
	@Test func userMountsAreKeptThroughTheLib() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				OS_FAMILY=freebsd
				WANT_MOUNT_SETUP=1
				SYSCTL_CONF="$D/sysctl.conf"
				sysctl() { echo "sysctl $*"; }
				printf 'kern.x=1\\n' > "$D/victim"
				ln -s "$D/victim" "$SYSCTL_CONF"
				sshfs_act_user_mounts 2>&1 | sed "s|$D|D|g"
				cat "$D/victim"
				[ -L "$SYSCTL_CONF" ] && echo "still a link"
				echo ---
				rm "$SYSCTL_CONF"
				sshfs_act_user_mounts >/dev/null
				sshfs_act_user_mounts >/dev/null
				cat "$SYSCTL_CONF"
				echo ---
				printf 'vfs.usermount = 1\\n' > "$SYSCTL_CONF"
				sshfs_act_user_mounts >/dev/null
				cat "$SYSCTL_CONF"
				rm "$SYSCTL_CONF"
				DRY_RUN=1
				sshfs_act_user_mounts | sed "s|$D|D|g"
				[ -e "$SYSCTL_CONF" ] || echo "nothing written"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[ok] user mounts allowed (vfs.usermount=1)
				[!!] could not keep vfs.usermount=1 across reboots: D/sysctl.conf is a symbolic \
				link
				   Add 'vfs.usermount=1' to D/sysctl.conf yourself.
				kern.x=1
				still a link
				---
				# BEGIN \(GuestScriptHarness.marker)-usermount
				vfs.usermount=1
				# END \(GuestScriptHarness.marker)-usermount
				---
				vfs.usermount = 1
				[..] would allowing user mounts:  sysctl vfs.usermount=1
				[ok] user mounts allowed (vfs.usermount=1)
				[..] would keep vfs.usermount=1 in D/sysctl.conf
				nothing written

				""", "\(shell): \(r.out)")
		}
	}

	// S43: openrc's boot-mount script is written whole by the lib — a link planted where it
	// goes is replaced, never written through — executable, with the marker line.
	@Test func openrcBootScriptIsWrittenByTheLib() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				UI_COLS=1000
				INIT=openrc
				SSHFS_BOOT_SCRIPT="$D/local.d/machman-sshfs.start"
				mkdir -p "$D/bin" "$D/local.d"
				printf '#!/bin/sh\necho "rc-update $*"\n' > "$D/bin/rc-update"
				chmod 755 "$D/bin/rc-update"
				PATH="$D/bin:$PATH"
				printf 'victim\n' > "$D/victim"
				ln -s "$D/victim" "$SSHFS_BOOT_SCRIPT"
				sshfsauto_write_boot_script "'sshfs' -o 'x' 'a' 'b' || true
				" | sed "s|$D|D|g"
				cat "$D/victim"
				[ -L "$SSHFS_BOOT_SCRIPT" ] || ls -l "$SSHFS_BOOT_SCRIPT" | cut -c1-10
				cat "$SSHFS_BOOT_SCRIPT"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[ok] sshfs folders mount at boot (D/local.d/machman-sshfs.start)
				   They connect once you approve this VM in Machman (guest -> host SSH).
				victim
				-rwxr-xr-x
				#!/bin/sh
				# \(GuestScriptHarness.marker) — machman sshfs automounts
				'sshfs' -o 'x' 'a' 'b' || true

				""", "\(shell): \(r.out)")
		}
	}

	// MARK: - The mount point (S43)

	// S43: "ready" came right after the step that failed it; now only a mount point that
	// exists, with the fuse driver loaded, is ready.
	@Test func theMountPointIsReadyOnlyWhenItIs() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				U="$(id -un)"
				GROUP="$(id -gn)"
				FUSE_PERSISTED=1
				OS_FAMILY=freebsd
				kldstat() { :; }
				kldload() { return 1; }
				MOUNTPOINT="$D/mnt"
				sshfs_act_fuse_ready 2>&1 | sed "s|$D|D|g"
				echo ---
				OS_FAMILY=debian
				: > "$D/file"
				MOUNTPOINT="$D/file/mnt"
				sshfs_act_fuse_ready 2>&1 | sed "s|$D|D|g"
				echo ---
				MOUNTPOINT="$D/mnt"
				sshfs_act_fuse_ready 2>&1 | sed "s|$D|D|g"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[!!] could not load the fusefs module
				   Load it yourself: kldload fusefs
				---
				[!!] could not create D/file/mnt
				   Create it yourself, or pass --mountpoint <path>.
				---
				[ok] D/mnt is ready for host folders

				""", "\(shell): \(r.out)")
		}
	}
}
