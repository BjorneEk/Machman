//
//  GuestScriptLibTests.swift
//  MachmanTests
//
//  The guest setup script's file-edit helpers (05-lib), run for real over scratch files
//  under every local POSIX shell. Root runs them over files other users own (~/.ssh, the
//  sshfs mount root, the report drop-box), so a link standing where a target or a temp
//  name goes is never written through, a file keeps its mode, and a file that is not ours
//  is not rewritten. As root and per distro, scripts/guest-regress proves the same over
//  the whole script.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct GuestScriptLibTests {

	// macOS's /bin/sh (bash in POSIX mode), dash and ksh93: three dialects where present.
	private static let shells = ["/bin/sh", "/bin/dash", "/bin/ksh"]
		.filter { FileManager.default.isExecutableFile(atPath: $0) }

	private static let marker = "machman-0123456789ab"

	// Sources 05-lib under `shell` in a fresh scratch directory ($D, also the working
	// directory) with MARKER set, then runs `body`; returns its exit status and output.
	private func run(_ body: String, under shell: String) throws -> (status: Int32, out: String) {
		let dir = TestEnvironment.scratchURL
			.appendingPathComponent("guestlib-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let lib = try #require(GuestSetupScript.parts.first { $0.name == "05-lib" })
		let script = "set -eu\n" + String(decoding: lib.bytes, as: UTF8.self)
			+ "\nMARKER=\(Self.marker)\nD='\(dir.path)'\ncd \"$D\"\n" + body + "\n"
		let url = dir.appendingPathComponent("probe.sh")
		try script.write(to: url, atomically: true, encoding: .utf8)
		let process = Process()
		process.executableURL = URL(fileURLWithPath: shell)
		process.arguments = [url.path]
		process.currentDirectoryURL = dir
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		try process.run()
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return (process.terminationStatus, String(decoding: data, as: UTF8.self))
	}

	// "<perms> <nlink>" for a path, from the same ls the script reads.
	private static let meta = #"meta() { ls -ln "$1" | awk '{ print substr($1, 1, 10), $2 }'; }"#

	// S19: an executable rc.local stays executable through the edit.
	@Test func stripBlockKeepsTheFileMode() throws {
		for shell in Self.shells {
			let r = try run(Self.meta + """

				printf '#!/bin/sh -e\\n# BEGIN %s\\nold\\n# END %s\\nexit 0\\n' \\
					"$MARKER" "$MARKER" > "$D/rc.local"
				chmod 755 "$D/rc.local"
				strip_block "$D/rc.local"
				meta "$D/rc.local"
				cat "$D/rc.local"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "-rwxr-xr-x 1\n#!/bin/sh -e\nexit 0\n", "\(shell)")
		}
	}

	// S20: the old fixed temp name, planted as a link by the file's owner, is never used.
	@Test func aPlantedTempNameIsNeverFollowed() throws {
		for shell in Self.shells {
			let r = try run("""
				echo secret > "$D/victim"
				printf 'mine\\n# BEGIN %s\\nours\\n# END %s\\n' "$MARKER" "$MARKER" > "$D/config"
				ln -s "$D/victim" "$D/config.machman-tmp"
				strip_block "$D/config"
				cat "$D/victim" "$D/config"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "secret\nmine\n", "\(shell)")
		}
	}

	// A linked target, a linked directory on the way, or a hard-linked file is refused with
	// a reason, and nothing is replaced.
	@Test func linksAreRefusedNeverReplaced() throws {
		for shell in Self.shells {
			let r = try run("""
				printf '# BEGIN %s\\nours\\n# END %s\\n' "$MARKER" "$MARKER" > "$D/real"
				ln -s "$D/real" "$D/linked"
				mkdir "$D/dir" && cp "$D/real" "$D/dir/f" && ln -s "$D/dir" "$D/linkdir"
				cp "$D/real" "$D/hard" && ln "$D/hard" "$D/hard2"
				rewrite_file "$D/linked" cat && echo "followed the link" || echo "$R_ERROR"
				rewrite_file "$D/linkdir/f" cat && echo "followed the dir" || echo "$R_ERROR"
				rewrite_file "$D/hard" cat && echo "split the hard link" || echo "$R_ERROR"
				strip_block "$D/linked" && echo "stripped through the link" || echo "kept: $R_ERROR"
				[ -L "$D/linked" ] && grep -c ours "$D/real"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out.contains("linked is a symbolic link"), "\(shell): \(r.out)")
			let kept = r.out.components(separatedBy: "\n").filter { $0.hasPrefix("kept: /") }
			#expect(kept.count == 1 && kept[0].hasSuffix("/linked is a symbolic link"),
				"\(shell): \(r.out)")
			#expect(r.out.contains("reached through a symbolic link"), "\(shell): \(r.out)")
			#expect(r.out.contains("hard has other hard links"), "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("\n1\n"), "\(shell): \(r.out)")
		}
	}

	// S20: a file without our block is not ours — not even rewritten in place, and a link
	// to one is no refusal either.
	@Test func filesWithoutTheMarkerAreLeftAlone() throws {
		for shell in Self.shells {
			let r = try run("""
				printf 'only the user\\n' > "$D/plain"
				ln -s "$D/plain" "$D/dotfile"
				before="$(ls -i "$D/plain" | awk '{ print $1 }')"
				strip_block "$D/plain"
				strip_block "$D/dotfile"
				[ "$(ls -i "$D/plain" | awk '{ print $1 }')" = "$before" ] && echo same
				[ -L "$D/dotfile" ] && echo link
				""", under: shell)
			#expect(r.out == "same\nlink\n", "\(shell): \(r.out)")
		}
	}

	// D14: an /etc/default/grub (or configuration.nix) holding nothing but our line empties
	// cleanly, and a link to such a file is refused by name like any other edit.
	@Test func aFileOfOnlyOurLinesEmptiesCleanly() throws {
		for shell in Self.shells {
			let r = try run("""
				printf 'G="$G console=hvc0" # %s\\n' "$MARKER" > "$D/grub"
				ln -s "$D/grub" "$D/linked"
				drop_lines "$D/linked" "# $MARKER" || echo "kept: $R_ERROR"
				drop_lines "$D/grub" "# $MARKER"
				[ -f "$D/grub" ] && [ ! -s "$D/grub" ] && echo empty
				ls -A "$D" | grep -c machman- || true
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out.hasPrefix("kept: /"), "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("/linked is a symbolic link\nempty\n0\n"), "\(shell): \(r.out)")
		}
	}

	// A whole-file write replaces whatever stands at the name — a link is never written
	// through, and a hard link's other name keeps the old content.
	@Test func writeFileReplacesALinkInsteadOfWritingThroughIt() throws {
		for shell in Self.shells {
			let r = try run(Self.meta + """

				echo secret > "$D/victim"
				ln -s "$D/victim" "$D/known"
				printf 'host key\\n' | write_file -m 600 "$D/known"
				echo old > "$D/h" && ln "$D/h" "$D/h2"
				printf 'new\\n' | write_file "$D/h"
				[ -L "$D/known" ] || meta "$D/known"
				cat "$D/known" "$D/victim" "$D/h" "$D/h2"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "-rw------- 1\nhost key\nsecret\nnew\nold\n", "\(shell): \(r.out)")
		}
	}

	// S19: rc.local stays executable, and our blocks land before its final exit.
	@Test func blocksLandBeforeAFinalExit() throws {
		for shell in Self.shells {
			let r = try run(Self.meta + """

				printf '#!/bin/sh -e\\n# rc.local\\n\\nexit 0\\n' > "$D/rc.local"
				chmod 755 "$D/rc.local"
				put_block "$D/rc.local" "$MARKER" 'mount one'
				put_block "$D/rc.local" "$MARKER-report" 'report'
				put_block "$D/rc.local" "$MARKER" 'mount two'
				meta "$D/rc.local"
				cat "$D/rc.local"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				-rwxr-xr-x 1
				#!/bin/sh -e
				# rc.local

				# BEGIN \(Self.marker)-report
				report
				# END \(Self.marker)-report
				# BEGIN \(Self.marker)
				mount two
				# END \(Self.marker)
				exit 0

				""", "\(shell): \(r.out)")
		}
	}

	// S19 on a guest an older run already hit: its blocks sit after the exit. Ours move
	// before it as they are rewritten; another VM's (a cloned disk's) stays inert there.
	@Test func blocksLeftAfterTheExitMoveBeforeIt() throws {
		for shell in Self.shells {
			let r = try run("""
				printf '#!/bin/sh -e\\n\\nexit 0\\n' > "$D/rc.local"
				for m in "$MARKER" "$MARKER-report" machman-ffffffffffff; do
					printf '# BEGIN %s\\nold\\n# END %s\\n' "$m" "$m" >> "$D/rc.local"
				done
				put_block "$D/rc.local" "$MARKER" 'mount'
				put_block "$D/rc.local" "$MARKER-report" 'report'
				cat "$D/rc.local"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				#!/bin/sh -e

				# BEGIN \(Self.marker)
				mount
				# END \(Self.marker)
				# BEGIN \(Self.marker)-report
				report
				# END \(Self.marker)-report
				exit 0
				# BEGIN machman-ffffffffffff
				old
				# END machman-ffffffffffff

				""", "\(shell): \(r.out)")
		}
	}

	// fstab escapes survive the body (no awk -v escape processing), and a file without a
	// final newline does not glue its last line to our block.
	@Test func blockBodiesArriveVerbatim() throws {
		for shell in Self.shells {
			let r = try run(#"""
				printf 'UUID=x / ext4 defaults 0 1' > "$D/fstab"
				put_block "$D/fstab" "$MARKER" 'h:/a\040b /mnt/a\040b fuse.sshfs nofail 0 0'
				cat "$D/fstab"
				"""#, under: shell)
			#expect(r.out == """
				UUID=x / ext4 defaults 0 1
				# BEGIN \(Self.marker)
				h:/a\\040b /mnt/a\\040b fuse.sshfs nofail 0 0
				# END \(Self.marker)

				""", "\(shell): \(r.out)")
		}
	}
}
