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

	// The share's host path is a link (<library>/.machman-shares/<marker>), and sshfs's root
	// check is an LSTAT: without a trailing slash the Mac's sftp-server answers "symlink" and
	// the mount fails "Not a directory". One slash, whatever the path ended with.
	@Test func theShareMountsThroughItsLinkWithATrailingSlash() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				GATEWAY=192.168.64.1
				SHARE_HOST_PATH="/Lib/.machman-shares/$MARKER"
				sshfsauto_entry @share
				printf '%s|%s\\n' "$R_MOUNT_WHAT" "$R_MOUNT_WHERE"
				SHARE_HOST_PATH="$SHARE_HOST_PATH/"
				sshfsauto_entry @share
				printf '%s\\n' "$R_MOUNT_WHAT"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			let link = "/Lib/.machman-shares/\(GuestScriptHarness.marker)/"
			#expect(r.out == """
				gustaf@192.168.64.1:\(link)|/mnt/machman/share
				gustaf@192.168.64.1:\(link)

				""", "\(shell): \(r.out)")
		}
	}

	// S46: S45's mechanism holds for any sshfs mount whose host folder is reached through a
	// link — sshfs's root LSTAT finds the link, not the folder — so every user mount gets the
	// one trailing slash the share's link has.
	@Test("S46: every sshfs host folder mounts through one trailing slash")
	func everyHostFolderMountsThroughOneTrailingSlash() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				GATEWAY=192.168.64.1
				MOUNTPOINT=/mnt/machman/mounts
				tab="$(printf '\\t')"
				MOUNTS_SSHFS="projects${tab}/Users/g/Projects link
				done${tab}/Users/g/Done/
				root${tab}/"
				for name in projects done root; do
					sshfsauto_entry "$name"
					printf '%s|%s\\n' "$R_MOUNT_WHAT" "$R_MOUNT_WHERE"
				done
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				gustaf@192.168.64.1:/Users/g/Projects link/|/mnt/machman/mounts/projects
				gustaf@192.168.64.1:/Users/g/Done/|/mnt/machman/mounts/done
				gustaf@192.168.64.1:/|/mnt/machman/mounts/root

				""", "\(shell): \(r.out)")
		}
	}

	// MARK: - NetBSD user mounts (S38)

	// S38: NetBSD lets users mount only with vfs.generic.usermount=1 — checked, never
	// assumed; asked like FreeBSD's vfs.usermount (no by default), set with sysctl -w, and
	// kept across reboots like it.
	@Test func netbsdUserMountsAreCheckedNotAssumed() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				OS_FAMILY=netbsd
				SYSCTL_CONF="$D/sysctl.conf"
				: > "$D/usermount"
				sysctl() {
					case "$1" in
					-n) [ -s "$D/usermount" ] && cat "$D/usermount" || echo 0 ;;
					-w) echo "sysctl $*" >> "$D/sysctl.log"; echo 1 > "$D/usermount" ;;
					esac
				}
				user_mounts_allowed && echo allowed || echo "not allowed"
				sshfs_decide >/dev/null 2>&1
				echo "$USER_MOUNT_PLAN"
				WANT_MOUNT_SETUP=1
				sshfs_decide >/dev/null 2>&1
				echo "$USER_MOUNT_PLAN"
				sshfs_act_user_mounts
				cat "$D/sysctl.log" "$SYSCTL_CONF"
				user_mounts_allowed && echo allowed
				WANT_MOUNT_SETUP=""
				sshfs_decide >/dev/null 2>&1
				echo "$USER_MOUNT_PLAN"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				not allowed
				left off — mount as root
				enable vfs.generic.usermount=1
				[ok] user mounts allowed (vfs.generic.usermount=1)
				sysctl -w vfs.generic.usermount=1
				# BEGIN \(GuestScriptHarness.marker)-usermount
				vfs.generic.usermount=1
				# END \(GuestScriptHarness.marker)-usermount
				allowed
				already allowed

				""", "\(shell): \(r.out)")
		}
	}

	// S54: NetBSD's rc raises kern.securelevel to 1, which refuses raising the knob while
	// the system runs; /etc/rc.d/sysctl applies sysctl.conf before that at the next boot. So
	// the block is kept whatever the live set does, a refusal at securelevel 1 is a note,
	// not a failed step, and the uninstall names the block even before that boot. Below
	// securelevel 1 a refusal still fails the step.
	@Test("S54: at securelevel 1 the user-mount sysctl is kept for the next boot, not failed")
	func netbsdUserMountsWaitForTheNextBoot() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				OS_FAMILY=netbsd
				WANT_MOUNT_SETUP=1
				SYSCTL_CONF="$D/sysctl.conf"
				LEVEL=1
				sysctl() {
					case "$1 $2" in
					"-n kern.securelevel") echo "$LEVEL" ;;
					"-n "*) echo 0 ;;
					*) echo "sysctl: $2: Operation not permitted" >&2; return 1 ;;
					esac
				}
				sshfs_act_user_mounts
				echo "failed=[$FAILED_STEPS]"
				cat "$SYSCTL_CONF"
				sshfs_uninstall | sed "s|$D|D|g"
				echo ---
				LEVEL=0
				rm "$SYSCTL_CONF"
				sshfs_act_user_mounts 2>&1
				echo "failed=[$FAILED_STEPS]"
				grep -c usermount "$SYSCTL_CONF"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			let block = "\(GuestScriptHarness.marker)-usermount"
			#expect(r.out == """
				   vfs.generic.usermount=1 takes effect at the next boot (securelevel 1 refuses \
				it now).
				failed=[]
				# BEGIN \(block)
				vfs.generic.usermount=1
				# END \(block)
				   vfs.generic.usermount=1 stays - 'sysctl -w vfs.generic.usermount=0' and the \
				\(block) block in D/sysctl.conf revert it.
				---
				[!!] could not set vfs.generic.usermount
				   Set it yourself: sysctl -w vfs.generic.usermount=1
				failed=[mount-setup]
				3

				""", "\(shell): \(r.out)")
		}
	}

	// S58: the uninstall named the user-mount sysctl as Machman's whenever it was on, even
	// when the guest or its admin had turned it on; now it names it only while this VM's
	// <marker>-usermount block keeps it (another VM's block, on a copy, is not this run's).
	@Test("S58: the uninstall names the user-mount sysctl only when this VM's block keeps it")
	func uninstallNamesOnlyMachmansUserMountSysctl() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				OS_FAMILY=freebsd
				SYSCTL_CONF="$D/sysctl.conf"
				sysctl() { echo 1; }
				sysrc() { :; }
				say_uninstall() { echo "$1:"; sshfs_uninstall | sed "s|$D|D|g"; }
				say_uninstall "no file"
				printf 'vfs.usermount=1\\n' > "$SYSCTL_CONF"
				say_uninstall "the admin's line"
				printf '# BEGIN machman-ba5eba11c0de-usermount\\nvfs.usermount=1\\n' \\
					> "$SYSCTL_CONF"
				printf '# END machman-ba5eba11c0de-usermount\\n' >> "$SYSCTL_CONF"
				say_uninstall "another VM's block"
				put_block "$SYSCTL_CONF" "$MARKER-usermount" "vfs.usermount=1"
				say_uninstall "this VM's block"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				no file:
				the admin's line:
				another VM's block:
				this VM's block:
				   vfs.usermount=1 stays - 'sysctl vfs.usermount=0' and the \
				\(GuestScriptHarness.marker)-usermount block in D/sysctl.conf revert it.

				""", "\(shell): \(r.out)")
		}
	}

	// MARK: - The mount point (S43)

	// S43: "ready" came right after the step that failed it; now only a mount point that
	// exists, with the fuse driver loaded, is ready.
	// S65 (review 4): root mounts each sshfs entry at boot as the Mac user with allow_other;
	// without default_permissions FUSE checks no mode in the guest, so every guest account
	// writes the share — Guest Setup's install.sh, which an admin then runs with sudo — and
	// every host folder, with the Mac user's rights. The read-only payload virtiofs gives is
	// gone on exactly the guests (the BSDs) that take the sshfs path. Agreed design (K6): a
	// host folder keeps allow_other under default_permissions; the share is root's alone.
	@Test("S65: boot-time sshfs mounts let the guest kernel check each file's mode")
	func bootMountsCheckModesInTheGuest() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				HOME_DIR="$D/home"
				U="$(id -un)"
				sshfsauto_options
				echo
				sshfsauto_options @share
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			let lines = r.out.split(separator: "\n")
				.map { $0.split(separator: ",").map(String.init) }
			let folder = lines.first ?? [], share = lines.dropFirst().first ?? []
			#expect(folder.contains("allow_other"), "\(shell): \(r.out)")
			#expect(folder.contains("default_permissions"), "\(shell): \(r.out)")
			#expect(share.contains("BatchMode=yes"), "\(shell): \(r.out)")
			#expect(!share.contains("allow_other") && !share.contains { $0.hasPrefix("uid=") },
				"the share is root's alone — \(shell): \(r.out)")
		}
	}

	// S66 (review 4): the uninstall rmdir'd the mount root whether this run created it or
	// found it, so a setup run with --mountpoint /mnt (normally empty) cost the guest /mnt.
	@Test("S66: the uninstall keeps a mount root that was there before setup")
	func uninstallKeepsAMountRootItFound() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				mount() { :; }
				mkdir "$D/mnt"
				ST_MOUNTPOINT="$D/mnt"
				ST_AUTOMOUNT_SSHFS=""
				uninstall_unmount_and_prune >/dev/null 2>&1
				if [ -d "$D/mnt" ]; then echo kept; else echo removed; fi
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "kept\n", "\(shell): \(r.out)")
		}
	}

	// S66: a run records the directories its mkdir made (made-dir) and chowns only those; a
	// --mountpoint that was there keeps its owner through setup and stays after the
	// uninstall, while a root a run made goes with every parent it made, once empty.
	@Test("S66: a mount root setup made goes with its parents, and a found one keeps its owner")
	func onlyAMountRootARunMadeIsChownedAndRemoved() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(GuestScriptStateTests.stateHere + #"""
				UI_COLS=1000
				OS_FAMILY=debian
				U="$(id -un)"
				GROUP="$(id -gn)"
				chown() { printf 'chown %s\n' "$*" >> "$D/chown.log"; }
				mount() { :; }
				show() { sed "s|$D|D|g; s|$U:$GROUP|U:G|g" "$@"; }
				mkdir "$D/found"
				MOUNTPOINT="$D/found"
				sshfs_decide >/dev/null 2>&1
				echo "plan: $MOUNT_PLAN" > "$D/out"
				sshfs_act_fuse_ready >> "$D/out"
				MOUNTPOINT="$D/made/machman/mounts"
				sshfs_act_fuse_ready >> "$D/out"
				show "$D/out" "$D/chown.log"
				ledger_values made-dir | show
				write_state sshfs
				read_state
				LEDGER_DONE=""
				sshfs_decide >/dev/null 2>&1
				echo "plan: $MOUNT_PLAN" | show
				ST_MOUNTPOINT="$MOUNTPOINT"
				uninstall_unmount_and_prune
				[ -d "$D/made" ] || echo "made: gone"
				ST_MOUNTPOINT="$D/found"
				uninstall_unmount_and_prune
				[ -d "$D/found" ] && echo "found: kept"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				plan: D/found (exists — its owner stays)
				[ok] D/found is ready for host folders
				[ok] D/made/machman/mounts is ready for host folders
				chown -h U:G D/made/machman/mounts
				D/made/machman/mounts
				D/made/machman
				D/made
				plan: D/made/machman/mounts (exists)
				made: gone
				found: kept

				""", "\(shell): \(r.out)")
		}
	}

	// S66: the uninstall's unmount pass rmdir'd every mount folder and the share root, made or
	// found, so a folder that was there before setup — /srv/www under --mountpoint /srv, a
	// mount named "www" — went with it. Only what a run made goes now; a found one stays.
	@Test("S66: a mount folder that was there stays at uninstall while one setup made goes")
	func uninstallKeepsAFoundMountFolder() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(GuestScriptStateTests.stateHere + #"""
				UI_COLS=1000
				mount() { :; }
				mkdir -p "$D/srv/www" "$D/share"
				SHARE_ROOT="$D/share"
				make_dir "$D/srv/made"
				ST_MOUNTPOINT="$D/srv"
				ST_AUTOMOUNT_SSHFS="www${T}made${T}@share"
				uninstall_unmount_and_prune
				for dir in srv srv/www srv/made share; do
					if [ -d "$D/$dir" ]; then echo "$dir: kept"; else echo "$dir: gone"; fi
				done
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				srv: kept
				srv/www: kept
				srv/made: gone
				share: kept

				""", "\(shell): \(r.out)")
		}
	}

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
