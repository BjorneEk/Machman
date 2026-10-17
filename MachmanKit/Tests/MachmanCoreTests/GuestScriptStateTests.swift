//
//  GuestScriptStateTests.swift
//  MachmanTests
//
//  The guest's state file (30-state): what a run records for the next one — the features it
//  configured and the details their re-runs, --report-only and --uninstall work from. Run
//  for real under every local POSIX shell, with the state dir moved into the probe's
//  scratch dir.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptStateTests {

	// The state dir, moved under $D for every probe, and the SSH host keys a copy renews.
	static let stateHere = """
		state_paths() { STATE_DIR="$D/state"; STATE_FILE="$STATE_DIR/state.env"; }
		state_paths
		SSH_HOST_KEY_DIR="$D/ssh"
		T="$(printf '\\t')"

		"""

	// Values are user text — a mountpoint, a user name, mount names — and come back byte
	// for byte: apostrophes, double quotes, backslashes and tabs included.
	@Test func stateValuesSurviveAnyText() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				SELECTED_FEATURES="ssh sshfsauto"
				MOUNTPOINT="/mnt/it's \"here\" \\ now"
				SSHFSAUTO_SELECTED="my docs"
				SSHFSAUTO_DONE="my docs${T}@share"
				U="o'brien"
				write_state "ssh sshfsauto"
				read_state
				[ "$ST_MOUNTPOINT" = "$MOUNTPOINT" ] && echo mountpoint
				[ "$ST_AUTOMOUNT_SSHFS" = "$SSHFSAUTO_DONE" ] && echo names
				[ "$ST_SSH_USER" = "$U" ] && echo user
				[ "$ST_CONFIGURED" = "ssh sshfsauto" ] && echo configured
				ls -ln "$STATE_FILE" | cut -c1-10
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "mountpoint\nnames\nuser\nconfigured\n-rw-------\n",
				"\(shell): \(r.out)")
		}
	}

	// S24: a run keeps the record of every feature it did not act on — consoles, the kernel
	// console and its method (the uninstall's grubby path), the SSH user, the sshfs
	// automounts (also when selected with nothing chosen) — while a selected feature's
	// record is this run's.
	@Test func unselectedFeaturesKeepTheirRecords() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				ST_CONSOLE_LOGINS="hvc0 hvc1"
				ST_KERNEL_CONSOLE=hvc1
				ST_KERNEL_CONSOLE_METHOD=grubby
				ST_SSH_USER=old
				ST_AUTOMOUNT_SSHFS=docs
				ST_MOUNTPOINT=/mnt/m
				show() {
					grep -E '^(CONSOLE_LOGINS|KERNEL_CONSOLE|KERNEL_CONSOLE_METHOD|SSH_USER)=' \
						"$STATE_FILE"
					grep -E '^(AUTOMOUNT_SSHFS|MOUNTPOINT)=' "$STATE_FILE"
					echo --
				}
				SELECTED_FEATURES="ssh sshfsauto"
				U=reg
				write_state "ssh"
				show
				SELECTED_FEATURES="console kernelconsole"
				CONSOLE_MANAGED=hvc0
				U=""
				write_state "console"
				show
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				CONSOLE_LOGINS='hvc0 hvc1'
				KERNEL_CONSOLE='hvc1'
				KERNEL_CONSOLE_METHOD='grubby'
				SSH_USER='reg'
				AUTOMOUNT_SSHFS='docs'
				MOUNTPOINT='/mnt/m'
				--
				CONSOLE_LOGINS='hvc0'
				KERNEL_CONSOLE='hvc1'
				KERNEL_CONSOLE_METHOD='grubby'
				SSH_USER='old'
				AUTOMOUNT_SSHFS='docs'
				MOUNTPOINT='/mnt/m'
				--

				""", "\(shell): \(r.out)")
		}
	}

	// S17: the automounts' names are a TAB-separated list (names carry spaces); a version-1
	// state's space-separated list (names then had none that survived) reads as one.
	@Test func spacedNamesSurviveTheStateFile() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				SELECTED_FEATURES="sshfsauto"
				SSHFSAUTO_SELECTED=x
				SSHFSAUTO_DONE="my docs${T}@share${T}docs"
				write_state "sshfsauto"
				sed -n 's/^STATE_VERSION=//p' "$STATE_FILE"
				read_state
				printf '%s\n' "$ST_AUTOMOUNT_SSHFS" | tr '\t' '|'
				printf "STATE_VERSION=1\nMARKER='%s'\nAUTOMOUNT_SSHFS='projects docs'\n" \
					"$MARKER" > "$STATE_FILE"
				read_state
				printf '%s\n' "$ST_AUTOMOUNT_SSHFS" | tr '\t' '|'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "2\nmy docs|@share|docs\nprojects|docs\n", "\(shell): \(r.out)")
		}
	}

	// S28: a --report-only run (the boot-time refresh) describes the last real run whole —
	// its status, one-sentence note, failed steps, errors and notes — from the state file,
	// so after a reboot "partial" still says why.
	@Test func reportOnlyReplaysTheLastRun() async throws {
		let dir = try GuestScriptHarness.scratch()
		for shell in GuestScriptHarness.shells {
			let run = try await GuestScriptHarness.run(Self.stateHere + #"""
				step_failed sshd "could not enable the service"
				report_note report-refresh "rc.local was not executable — re-enabled"
				write_state "ssh"
				"""#, under: shell, in: dir)
			#expect(run.status == 0, "\(shell): \(run.out)")
			let boot = try await GuestScriptHarness.run(Self.stateHere + #"""
				read_state
				REPORT_ONLY=1
				FEATURES=""
				state_replay_outcome
				write_report
				grep -E '^(STATUS|FAILED_STEPS|NOTE|ERROR_[0-9]*|NOTE_[0-9]*)=' \
					"$D/GuestReport/report.env"
				"""#, under: shell, in: dir)
			#expect(boot.status == 0, "\(shell): \(boot.out)")
			#expect(boot.out == """
				STATUS=partial
				FAILED_STEPS=sshd
				NOTE=could not enable the service
				ERROR_1=sshd: could not enable the service
				NOTE_1=report-refresh: rc.local was not executable — re-enabled

				""", "\(shell): \(boot.out)")
		}
	}

	// A state file an older script wrote ('…' around raw text, apostrophes unescaped) reads
	// as it was meant.
	@Test func olderStateFilesStillRead() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				mkdir -p "$STATE_DIR"
				printf "STATE_VERSION=1\nSCRIPT_VERSION=4\nMARKER='%s'\n" "$MARKER" > "$STATE_FILE"
				printf "CONFIGURED='ssh sshfsauto'\nLAST_STATUS='ok'\n" >> "$STATE_FILE"
				printf "SSH_USER='reg'\n" >> "$STATE_FILE"
				printf "AUTOMOUNT_SSHFS='docs'\nMOUNTPOINT='/mnt/it's'\n" >> "$STATE_FILE"
				read_state
				printf '%s|%s|%s|%s|%s\n' "$ST_CONFIGURED" "$ST_LAST_STATUS" "$ST_SSH_USER" \
					"$ST_AUTOMOUNT_SSHFS" "$ST_MOUNTPOINT"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "ssh sshfsauto|ok|reg|docs|/mnt/it's\n", "\(shell): \(r.out)")
		}
	}

	// PR28: what a run created that was not there before (an rc.local, a service it enabled,
	// a mount root, boot arguments) is one ledger in the state, so the uninstall reverts
	// exactly that. A later run keeps every earlier run's entries and adds its own, an entry
	// a run undid goes, and values come back whole — spaces, apostrophes and all.
	@Test("PR28: the state's ledger keeps what every run created, spaces and all")
	func theLedgerKeepsWhatEveryRunCreated() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				ledger_note rc-local created
				ledger_note mount-root "/mnt/it's my root"
				ledger_note rc-local created
				write_state ""
				grep '^LEDGER_' "$STATE_FILE"
				echo --
				read_state
				LEDGER_DONE=""
				ledger_has rc-local created && echo "has rc.local"
				ledger_has mount-root || echo "an entry matches whole"
				ledger_values mount-root
				ledger_note openrc-local
				ledger_forget rc-local created
				ledger_has rc-local created || echo "rc.local forgotten"
				write_state ""
				grep '^LEDGER_' "$STATE_FILE"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == #"""
				LEDGER_1='rc-local created'
				LEDGER_2='mount-root /mnt/it'\''s my root'
				--
				has rc.local
				an entry matches whole
				/mnt/it's my root
				rc.local forgotten
				LEDGER_1='mount-root /mnt/it'\''s my root'
				LEDGER_2='openrc-local'

				"""#, "\(shell): \(r.out)")
		}
	}

	// S59: the uninstall said kld_list keeps fusefs and virtio_console, with a revert,
	// whenever kld_list held them — the admin's own entries too. A run now records the
	// entries it adds (a later run that finds them in place keeps the record), and the
	// uninstall names only those; a state without the record (v6 and older) added none.
	@Test("S59: the uninstall names only the kld_list entries a run added")
	func uninstallNamesOnlyTheKldListEntriesARunAdded() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				UI_COLS=1000
				OS_FAMILY=freebsd
				GETTY_MECH=ttys
				U="$(id -un)"
				GROUP="$(id -gn)"
				MOUNTPOINT="$D/mnt"
				kldstat() { echo 'fusefs.ko virtio_console.ko'; }
				sysrc() {
					case "$1" in
					-n) tr '\n' ' ' < "$D/kld"; echo ;;
					kld_list+=*) echo "${1#kld_list+=}" >> "$D/kld" ;;
					esac
				}
				strip_block() { :; }
				restore_superseded() { :; }
				console_uninstall_reload() { :; }
				CONSOLE_SELECTED=ttyV0.0
				CONSOLE_ACTIONS=ttyV0.0=report
				a_run() {
					KLD_ADDED=""
					FUSE_PERSISTED=0
					fuse_persisted && FUSE_PERSISTED=1
					sshfs_act_fuse_ready >/dev/null
					console_act >/dev/null
					write_state sshfs
				}
				uninstall() {
					KLD_ADDED=""
					echo "$1:"
					read_state
					sshfs_uninstall
					console_uninstall
				}
				: > "$D/kld"
				a_run
				read_state
				a_run
				grep '^KLD_ADDED=' "$STATE_FILE" || echo "no record"
				uninstall "both added"
				ST_KLD_ADDED=""
				echo virtio_console > "$D/kld"
				a_run
				uninstall "fusefs added"
				printf "MARKER='%s'\n" "$MARKER" > "$STATE_FILE"
				printf 'fusefs\nvirtio_console\n' > "$D/kld"
				uninstall "a v6 state"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				KLD_ADDED='fusefs virtio_console'
				both added:
				   kld_list keeps fusefs (sshfs stays usable) - 'sysrc kld_list-=fusefs' reverts \
				it.
				   kld_list keeps virtio_console (the console devices stay) - 'sysrc \
				kld_list-=virtio_console' reverts it.
				fusefs added:
				   kld_list keeps fusefs (sshfs stays usable) - 'sysrc kld_list-=fusefs' reverts \
				it.
				a v6 state:

				""", "\(shell): \(r.out)")
		}
	}

	// S55: a duplicate's disk keeps its source's machine id, which systemd-networkd derives
	// its DHCP client id from, and dhcpcd's DUID: the copy leased the source's address. A run
	// that finds another VM's state gives the guest a new machine id (version 4, the file's
	// mode kept, dbus's copy following) and drops dhcpcd's identity; a guest that is no copy,
	// a machine id that is a link and a guest that isn't Linux keep theirs.
	@Test("S55: a copy's run gives a Linux guest a new machine id, and dbus's copy follows")
	func aCopyGetsAMachineIdOfItsOwn() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				UI_COLS=1000
				OS=Linux
				mkdir -p "$D/id" "$STATE_DIR"
				MACHINE_ID_FILE="$D/id/machine-id"
				DBUS_MACHINE_ID_FILE="$D/id/dbus-machine-id"
				DHCPCD_ID_FILES="$D/id/duid $D/id/secret $D/id/none"
				old=0123456789abcdef0123456789abcdef
				printf '%s\n' "$old" > "$MACHINE_ID_FILE"
				chmod 444 "$MACHINE_ID_FILE"
				printf '%s\n' "$old" > "$DBUS_MACHINE_ID_FILE"
				printf 'duid\n' > "$D/id/duid"
				printf 'secret\n' > "$D/id/secret"
				read_state
				identity_plan
				identity_act
				echo "no copy: [$(identity_to_renew)] $(cat "$MACHINE_ID_FILE")"
				printf "MARKER='machman-ffffffffffff'\n" > "$STATE_FILE"
				read_state
				identity_plan
				identity_act
				new="$(cat "$MACHINE_ID_FILE")"
				case "$new" in
				"$old") echo "the source's id" ;;
				*[!0-9a-f]*) echo "not hex: $new" ;;
				????????????4???[89ab]???????????????) echo "a new version-4 id" ;;
				*) echo "an odd id: $new" ;;
				esac
				cmp -s "$MACHINE_ID_FILE" "$DBUS_MACHINE_ID_FILE" && echo "dbus's copy follows"
				ls -ln "$MACHINE_ID_FILE" | cut -c1-10
				ls "$D/id"
				echo "renewed=$IDENTITY_RENEWED failed=[$FAILED_STEPS]"
				rm "$MACHINE_ID_FILE"
				ln -s "$DBUS_MACHINE_ID_FILE" "$MACHINE_ID_FILE"
				echo "a link: [$(identity_to_renew)]"
				rm "$MACHINE_ID_FILE"
				cp "$DBUS_MACHINE_ID_FILE" "$MACHINE_ID_FILE"
				OS=FreeBSD
				echo "not Linux: [$(identity_to_renew)]"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				no copy: [] 0123456789abcdef0123456789abcdef
				   this guest looks cloned from another Machman VM - treating it as new
				  identity         a new machine id and DHCP client id for this copy - its own \
				address from the next boot
				[ok] gave this copy a machine id of its own
				[ok] dropped the source's DHCP client id (dhcpcd makes one at the next boot)
				a new version-4 id
				dbus's copy follows
				-r--r--r--
				dbus-machine-id
				machine-id
				renewed=1 failed=[]
				a link: []
				not Linux: []

				""", "\(shell): \(r.out)")
		}
	}

	// Review F8 (S55, script half): a copy keeps its source's SSH host keys, so a client
	// that mixed the two VMs up (an address, a client id) logged into the source with no
	// warning. A copy's run makes each host key anew (a link stays, named, and a type
	// ssh-keygen can no longer make, such as DSA, keeps its old key quietly) and reloads
	// sshd, so the report it writes carries the key sshd serves; where the reload fails, it
	// says when sshd takes them up. A BSD copy, whose dhcpcd client id the run renews, gets
	// new keys too, reloaded through its rc.
	@Test("S55: a copy's run gives the guest new ssh host keys")
	func aCopyGetsSSHHostKeysOfItsOwn() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				UI_COLS=1000
				OS=Linux
				INIT=systemd
				SSHD=running
				SSHD_UNIT=ssh
				MACHINE_ID_FILE="$D/none"
				DHCPCD_ID_FILES="$D/none"
				K="$SSH_HOST_KEY_DIR"
				mkdir -p "$K" "$STATE_DIR"
				ssh-keygen -q -t ed25519 -N '' -f "$K/ssh_host_ed25519_key"
				ssh-keygen -q -t ecdsa -N '' -f "$D/elsewhere_ecdsa_key"
				ln -s "$D/elsewhere_ecdsa_key" "$K/ssh_host_ecdsa_key"
				echo "an old DSA key" > "$K/ssh_host_dsa_key"
				# OpenSSH 9.8 dropped DSA: this ssh-keygen can't make one, whatever the Mac's can.
				mkdir -p "$D/bin"
				{
					echo '#!/bin/sh'
					echo 'case " $* " in *" -t dsa "*) echo "unknown key type dsa" >&2; exit 255 ;;'
					echo 'esac'
					echo 'exec /usr/bin/ssh-keygen "$@"'
				} > "$D/bin/ssh-keygen"
				chmod +x "$D/bin/ssh-keygen"
				PATH="$D/bin:$PATH"
				systemctl() { echo "systemctl $*" >> "$D/systemctl.log"; }
				fp() { ssh-keygen -lf "$1" | cut -d ' ' -f 2; }
				old="$(fp "$K/ssh_host_ed25519_key.pub")"
				link="$(fp "$D/elsewhere_ecdsa_key.pub")"
				read_state
				echo "not a copy: [$(identity_to_renew)]"
				printf "MARKER='machman-ffffffffffff'\n" > "$STATE_FILE"
				read_state
				identity_plan
				identity_act | sed "s|$D|D|g"
				new="$(fp "$K/ssh_host_ed25519_key.pub")"
				[ -n "$new" ] && [ "$new" != "$old" ] && echo "a new ed25519 key"
				[ "$(ssh-keygen -y -f "$K/ssh_host_ed25519_key" | cut -d ' ' -f 1,2)" \
					= "$(cut -d ' ' -f 1,2 "$K/ssh_host_ed25519_key.pub")" ] && echo "its pair"
				ls -ln "$K/ssh_host_ed25519_key" | cut -c1-10
				[ "$(fp "$D/elsewhere_ecdsa_key.pub")" = "$link" ] && echo "the link's key stays"
				cat "$K/ssh_host_dsa_key"
				ls "$K" | paste -s -d ' ' -
				cat "$D/systemctl.log"
				echo "renewed=$IDENTITY_RENEWED failed=[$FAILED_STEPS]"
				systemctl() { return 1; }
				identity_act | sed "s|$D|D|g"
				echo ---
				OS=FreeBSD
				INIT=freebsd-rc
				printf 'duid\n' > "$D/duid"
				DHCPCD_ID_FILES="$D/duid"
				old="$(fp "$K/ssh_host_ed25519_key.pub")"
				service() { echo "service $*" >> "$D/service.log"; }
				identity_plan
				identity_act | sed "s|$D|D|g"
				[ "$(fp "$K/ssh_host_ed25519_key.pub")" != "$old" ] && echo "a new ed25519 key"
				cat "$D/service.log"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				not a copy: []
				   this guest looks cloned from another Machman VM - treating it as new
				  identity         new SSH host keys for this copy
				[ok] gave this copy SSH host keys of its own
				   D/ssh/ssh_host_ecdsa_key is a link, so it stays and this copy serves its \
				source's host key until you replace it.
				a new ed25519 key
				its pair
				-rw-------
				the link's key stays
				an old DSA key
				ssh_host_dsa_key ssh_host_ecdsa_key ssh_host_ed25519_key ssh_host_ed25519_key.pub
				systemctl reload ssh
				renewed=0 failed=[]
				[ok] gave this copy SSH host keys of its own
				   sshd serves them from the next boot.
				   D/ssh/ssh_host_ecdsa_key is a link, so it stays and this copy serves its \
				source's host key until you replace it.
				---
				  identity         a new DHCP client id and SSH host keys for this copy - its own \
				address from the next boot
				[ok] dropped the source's DHCP client id (dhcpcd makes one at the next boot)
				[ok] gave this copy SSH host keys of its own
				   D/ssh/ssh_host_ecdsa_key is a link, so it stays and this copy serves its \
				source's host key until you replace it.
				a new ed25519 key
				service sshd reload

				""", "\(shell): \(r.out)")
		}
	}

	// Review F20 (S55): a host key that is a link (NixOS impermanence keeps them on
	// /persist, which a duplicate clones too) is someone else's arrangement and stays, but it
	// stayed silently, so the copy served its source's key with no word; with only linked
	// keys there was nothing in the identity step at all. Each linked key is named now.
	@Test("S55: a copy keeps a linked ssh host key and says so")
	func aCopySaysWhichHostKeysAreLinks() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.stateHere + #"""
				UI_COLS=1000
				OS=FreeBSD
				INIT=freebsd-rc
				SSHD=installed
				DHCPCD_ID_FILES="$D/none"
				K="$SSH_HOST_KEY_DIR"
				mkdir -p "$K" "$STATE_DIR" "$D/persist"
				ssh-keygen -q -t ed25519 -N '' -f "$K/ssh_host_ed25519_key"
				ssh-keygen -q -t ecdsa -N '' -f "$D/persist/ssh_host_ecdsa_key"
				ln -s "$D/persist/ssh_host_ecdsa_key" "$K/ssh_host_ecdsa_key"
				fp() { ssh-keygen -lf "$1" | cut -d ' ' -f 2; }
				old="$(fp "$K/ssh_host_ed25519_key.pub")"
				kept="$(fp "$D/persist/ssh_host_ecdsa_key.pub")"
				printf "MARKER='machman-ffffffffffff'\n" > "$STATE_FILE"
				read_state
				identity_plan
				identity_act 2>&1 | sed "s|$D|D|g"
				[ "$(fp "$K/ssh_host_ed25519_key.pub")" != "$old" ] && echo "a new ed25519 key"
				[ -L "$K/ssh_host_ecdsa_key" ] \
					&& [ "$(fp "$D/persist/ssh_host_ecdsa_key.pub")" = "$kept" ] \
					&& echo "the link and its target stay"
				echo ---
				rm "$K/ssh_host_ed25519_key" "$K/ssh_host_ed25519_key.pub"
				identity_plan
				identity_act 2>&1 | sed "s|$D|D|g"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				   this guest looks cloned from another Machman VM - treating it as new
				  identity         new SSH host keys for this copy
				[ok] gave this copy SSH host keys of its own
				   D/ssh/ssh_host_ecdsa_key is a link, so it stays and this copy serves its \
				source's host key until you replace it.
				a new ed25519 key
				the link and its target stay
				---
				   D/ssh/ssh_host_ecdsa_key is a link, so it stays and this copy serves its \
				source's host key until you replace it.

				""", "\(shell): \(r.out)")
		}
	}
}
