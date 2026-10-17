//
//  GuestScriptReportTests.swift
//  MachmanTests
//
//  What the guest setup script reports (80-report) — the AUTOMOUNT_, ERROR_ and NOTE_
//  rows the host parses, and what a --report-only run rebuilds from the state file — run
//  for real under every local POSIX shell through GuestScriptHarness.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptReportTests {

	// S9: a --report-only run lists the share's sshfs automount where its entry mounts it
	// (the share root, as sshfsauto_entry does), every other mount under the mount root.
	@Test func shareRowKeepsTheShareRoot() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				T="$(printf '\t')"
				ST_AUTOMOUNT_SSHFS="@share${T}docs"
				ST_MOUNTPOINT=/mnt/machman/mounts
				automount_lines_kept
				printf '%s\n' "$AUTOMOUNT_LINES" | tr '\t' '|'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				sshfs|@share|/mnt/machman/share
				sshfs|docs|/mnt/machman/mounts/docs

				""", "\(shell): \(r.out)")
		}
	}

	// S14: systemd's sshfs automounts are started right after the reload that creates their
	// units, so the folders mount on first access without a reboot — and the run says so
	// only for those it armed; without systemd-escape they arm at the next boot.
	@Test func automountsArmNow() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				T="$(printf '\t')"
				INIT=systemd
				U="$(id -un)"
				GROUP="$(id -gn)"
				HOME_DIR="$D/home"
				MOUNTPOINT="$D/mounts"
				GATEWAY=192.168.64.1
				MOUNTS_SSHFS="docs${T}/Users/g/Docs"
				SSHFSAUTO_SELECTED=docs
				UI_COLS=200
				put_block() { return 0; }
				systemctl() { printf 'systemctl %s\n' "$*" >> "$D/log"; }
				mkdir -p "$D/bin"
				printf '#!/bin/sh\necho "escape $*" >> "%s/log"\necho mnt-docs.automount\n' \
					"$D" > "$D/bin/systemd-escape"
				chmod 755 "$D/bin/systemd-escape"
				SYSTEM_PATH="$PATH"
				PATH="$D/bin:$PATH"
				sshfsauto_act 2>&1 | grep -v connect
				PATH="$SYSTEM_PATH"
				sed "s|$D|D|" "$D/log"
				rm -f "$D/log"
				sshfsauto_act 2>&1 | grep -v connect
				sed "s|$D|D|" "$D/log"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[ok] sshfs automounts armed (docs) - each mounts on first access
				systemctl daemon-reload
				escape -p --suffix=automount -- D/mounts/docs
				systemctl start mnt-docs.automount
				[!!] sshfs automounts (docs) are armed at the next boot
				systemctl daemon-reload

				""", "\(shell): \(r.out)")
		}
	}

	// S27: the boot-time copy reports where its machman.env says (the share's drop-box, as
	// the setup run resolved it) and does nothing else: any other run is refused. The
	// share's own copy, without that line, reports beside its payload as before.
	@Test func bootCopyIsReportOnly() async throws {
		let env = ["BOOT_REPORT_DIR": "/mnt/machman/share/GuestReport"]
		for shell in GuestScriptHarness.shells {
			let copy = try await GuestScriptHarness.run(#"echo "$REPORT_DIR""#, under: shell,
				env: env, args: ["--report-only"])
			#expect(copy.status == 0, "\(shell): \(copy.out)")
			#expect(copy.out == "/mnt/machman/share/GuestReport\n", "\(shell): \(copy.out)")
			let refused = try await GuestScriptHarness.run("echo ran", under: shell,
				env: env, args: ["-y", "--ssh"])
			#expect(refused.status == 3, "\(shell): \(refused.out)")
			#expect(refused.out.contains("Machman's boot-time report copy"), "\(shell)")
			#expect(!refused.out.contains("ran"), "\(shell): \(refused.out)")
			let share = try await GuestScriptHarness.run(#"echo "${REPORT_DIR##*/}""#, under: shell,
				args: ["-y", "--ssh"])
			#expect(share.out == "GuestReport\n", "\(shell): \(share.out)")
		}
	}

	// S27: the hook's copy lives beside the state — the script itself (root-only), its
	// machman.env plus where reports go, and the files it reads — and macOS's launchd hook
	// runs it, loaded at the next boot (never racing this run's own report).
	@Test func bootCopyInstallsBesideTheState() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				state_paths() { STATE_DIR="$D/state"; STATE_FILE="$STATE_DIR/state.env"; }
				state_paths
				LAUNCHD_DIR="$D/LaunchDaemons"
				mkdir -p "$LAUNCHD_DIR"
				INIT=launchd
				OS_FAMILY=darwin
				launchctl() { printf '%s\n' "$*" >> "$D/launchctl.log"; }
				printf 'ssh-ed25519 AAAA host\n' > "$PAYLOAD_DIR/host_key.pub"
				report_hook_install
				ls -ln "$D/state" | awk 'NR > 1 { print substr($1, 1, 10), $NF }'
				cmp -s "$D/state/report.sh" "$0" && echo "the copy is the script"
				tail -n 1 "$D/state/machman.env" | sed "s|$D|D|"
				grep -c "<string>$D/state/report.sh</string>" \
					"$LAUNCHD_DIR/com.machman.report.plist"
				cat "$D/launchctl.log"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				-rw-r--r-- host_key.pub
				-rw------- machman.env
				-rwx------ report.sh
				the copy is the script
				BOOT_REPORT_DIR='D/GuestReport'
				1
				bootout system/com.machman.report

				""", "\(shell): \(r.out)")
		}
	}

	// S53: NetBSD's ifconfig prints the address with its prefix length (inet 10.0.2.15/24),
	// which the summary put in its ssh line and the host refused as no address; FreeBSD's
	// and OpenBSD's print it bare, with a netmask after it.
	@Test("S53: a NetBSD address reads without its prefix length")
	func bsdAddressesCarryNoPrefixLength() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				route() {
					printf '   route to: default\n    gateway: 10.0.2.2\n  interface: vioif0\n'
				}
				ifconfig() { printf '%s: flags=0x8843<UP> mtu 1500\n\tinet %s\n' "$1" "$INET"; }
				for OS in NetBSD FreeBSD OpenBSD; do
					case "$OS" in
					NetBSD) INET='10.0.2.15/24 broadcast 10.0.2.255 flags 0' ;;
					*) INET='10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255' ;;
					esac
					IP=""
					find_addresses
					echo "$OS $IP $GATEWAY"
				done
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				NetBSD 10.0.2.15 10.0.2.2
				FreeBSD 10.0.2.15 10.0.2.2
				OpenBSD 10.0.2.15 10.0.2.2

				""", "\(shell): \(r.out)")
		}
	}

	// S31: --at-boot is the boot hook's --report-only, and it first waits for the share's
	// drop-box and a default route (the sshfs automounts need one) — polling, bounded — so
	// a boot report never marks them unavailable before DHCP. The locked copy accepts it.
	@Test func bootWaitWaitsForTheRouteAndTheShare() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				echo "report-only=$REPORT_ONLY at-boot=$AT_BOOT"
				BOOT_WAIT_POLL=0
				REPORT_DIR="$D/later"
				GATEWAY=""
				calls=0
				find_addresses() {
					calls=$((calls + 1))
					[ "$calls" -lt 2 ] || mkdir -p "$REPORT_DIR"
					[ "$calls" -lt 3 ] || GATEWAY=192.168.64.1
					return 0
				}
				boot_wait
				echo "probes=$calls"
				REPORT_DIR="$D/never"
				GATEWAY=""
				calls=0
				BOOT_WAIT_SECONDS=0
				boot_wait
				echo "probes=$calls"
				"""#, under: shell, env: ["BOOT_REPORT_DIR": "/mnt/machman/share/GuestReport"],
				args: ["--at-boot"])
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "report-only=1 at-boot=1\nprobes=3\nprobes=1\n", "\(shell): \(r.out)")
		}
	}

	// S36: a note (a repair made, a boot refresh that will not run) is reported as NOTE_<n>,
	// after the errors, and is no error: a clean run's report carries no ERROR_ line.
	@Test func reportNotesTravelAsNotes() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				FEATURES=""
				report_note report-refresh "rc.local was not executable — re-enabled"
				step_failed sshd "could not enable the service"
				write_report
				grep -E '^(STATUS|ERROR_|NOTE_)' "$D/GuestReport/report.env"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("""
				STATUS=partial
				ERROR_1=sshd: could not enable the service
				NOTE_1=report-refresh: rc.local was not executable — re-enabled

				"""), "\(shell): \(r.out)")
		}
	}

	// S17: a row whose name has a space is TAB-separated, so the host reads it whole; every
	// other row stays space-separated, as every daemon reads it. The feature's detail lists
	// the names comma-separated.
	@Test func reportRowsKeepSpacedNamesWhole() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				T="$(printf '\t')"
				FEATURES=sshfsauto
				avail_sshfsauto=1
				SSHFSAUTO_DONE="my docs${T}docs"
				AUTOMOUNT_LINES="sshfs${T}my docs${T}/mnt/machman/mounts/my docs
				sshfs${T}docs${T}/mnt/machman/mounts/docs"
				write_report
				grep -E '^(AUTOMOUNT_|FEATURE_)' "$D/GuestReport/report.env" | tr '\t' '|'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				FEATURE_sshfsAutomount=configured my docs, docs
				AUTOMOUNT_1=sshfs|my docs|/mnt/machman/mounts/my docs
				AUTOMOUNT_2=sshfs docs /mnt/machman/mounts/docs

				""", "\(shell): \(r.out)")
		}
	}

	// S64: an /etc/rc.local setup created (a bare "#!/bin/sh", 0755) or made executable
	// outlived the uninstall, undisclosed. The ledger records both; once its blocks are out,
	// a created file holding only that first line goes, one the guest has added to stays and
	// is named, an exec bit a run turned on goes off — and one it found on stays on.
	@Test(
		"""
		S64: the uninstall removes an rc.local setup created and turns off an exec bit it \
		turned on
		""")
	func uninstallRevertsTheRcLocalARunMade() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				UI_COLS=1000
				OS=Linux
				RC_LOCAL="$D/rc.local"
				mode() { ls -l "$RC_LOCAL" | cut -c1-10; }
				rc_local_put "$MARKER-report" "echo hook"
				mode
				strip_block "$RC_LOCAL" "$MARKER-report"
				rc_local_revert
				[ -e "$RC_LOCAL" ] || echo "created: removed"
				echo ---
				LEDGER_DONE=""
				rc_local_put "$MARKER" "mount"
				echo "echo mine" >> "$RC_LOCAL"
				strip_block "$RC_LOCAL"
				rc_local_revert
				cat "$RC_LOCAL"
				echo ---
				LEDGER_DONE=""
				old=machman-0ddc105e9999
				printf '#!/bin/sh\n# BEGIN %s\nold\n# END %s\n' "$old" "$old" > "$RC_LOCAL"
				chmod 644 "$RC_LOCAL"
				rc_local_ready report-refresh >/dev/null 2>&1
				mode
				rc_local_revert
				mode
				echo ---
				LEDGER_DONE=""
				chmod 755 "$RC_LOCAL"
				rc_local_revert
				mode
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				-rwxr-xr-x
				[ok] removed /etc/rc.local (setup created it)
				created: removed
				---
				   /etc/rc.local stays - setup created it, and it holds other lines now.
				#!/bin/sh
				echo mine
				---
				-rwxr-xr-x
				   /etc/rc.local is not executable again, as before setup.
				-rw-r--r--
				---
				-rwxr-xr-x

				""", "\(shell): \(r.out)")
		}
	}

	// S63: the boot hooks enabled openrc's local service (it runs /etc/local.d/*.start) and
	// the uninstall left it on, undisclosed. A run that adds it records so; the uninstall
	// takes it back when no other boot script is left there, else names it with its revert,
	// and one the guest had enabled is never recorded nor touched.
	@Test(
		"""
		S63: the uninstall drops the local service only when a run added it and no other \
		boot script uses it
		""")
	func uninstallDropsTheLocalServiceARunAdded() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				UI_COLS=1000
				OPENRC_LOCAL_D="$D/local.d"
				mkdir -p "$OPENRC_LOCAL_D" "$D/bin"
				: > "$D/runlevel"
				cat > "$D/bin/rc-update" <<SH
				#!/bin/sh
				case "\$1" in
				show) cat "$D/runlevel" ;;
				add) printf '      %s | %s\n' "\$2" "\$3" >> "$D/runlevel" ;;
				del) grep -v " \$2 " "$D/runlevel" > "$D/rl.tmp"; mv "$D/rl.tmp" "$D/runlevel" ;;
				esac
				SH
				chmod 755 "$D/bin/rc-update"
				PATH="$D/bin:$PATH"
				openrc_local_enable
				cat "$D/runlevel"
				openrc_local_revert
				echo "after: [$(cat "$D/runlevel")]"
				echo ---
				openrc_local_enable
				: > "$OPENRC_LOCAL_D/mine.start"
				openrc_local_revert
				cat "$D/runlevel"
				echo ---
				LEDGER_DONE=""
				rm "$OPENRC_LOCAL_D/mine.start"
				openrc_local_enable
				ledger_has openrc-local || echo "found: not recorded"
				openrc_local_revert
				cat "$D/runlevel"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				      local | default
				after: []
				---
				   the local service stays in the default runlevel (other boot scripts use it) \
				- 'rc-update del local default' reverts it.
				      local | default
				---
				found: not recorded
				      local | default

				""", "\(shell): \(r.out)")
		}
	}

	// S65 (v8): the report names the exact copy that ran — SCRIPT_CKSUM, what the guest's own
	// cksum prints for the running script — right beside SCRIPT_VERSION.
	@Test("S65: a report carries the running script's cksum beside its version")
	func theReportCarriesTheScriptsCksum() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				write_report
				own="$(cksum < "$PAYLOAD_DIR/${0##*/}" | awk '{ print $1, $2 }')"
				sed -n '2p' "$D/GuestReport/report.env" | sed "s/=$own\$/=<its cksum>/"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "SCRIPT_CKSUM=<its cksum>\n", "\(shell): \(r.out)")
		}
	}

	// S67: a copy run as it is (--changed) leaves itself beside its report, where Machman keeps
	// it as a script changed on this VM; a real run of an unchanged copy takes a stale one
	// away, and a report-only run (the boot hook) leaves the drop-box's script alone.
	@Test(
		"""
		S67: a run of a changed copy leaves its script beside the report, and an unchanged \
		run leaves none
		""")
	func aChangedRunLeavesItsScript() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				SETUP_CKSUM="0 0"
				WANT_CHANGED=1
				payload_check 2>/dev/null
				write_report
				cmp -s "$PAYLOAD_DIR/${0##*/}" "$D/GuestReport/install.sh" && echo "changed: left"
				PAYLOAD_CHANGED=0
				REPORT_ONLY=1
				write_report
				[ -f "$D/GuestReport/install.sh" ] && echo "report-only: kept"
				REPORT_ONLY=0
				write_report
				[ -f "$D/GuestReport/install.sh" ] || echo "unchanged: taken away"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "changed: left\nreport-only: kept\nunchanged: taken away\n",
				"\(shell): \(r.out)")
		}
	}
}
