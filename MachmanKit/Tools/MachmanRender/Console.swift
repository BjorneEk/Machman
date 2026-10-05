//
//  Console.swift
//  MachmanRender
//
//  The tool's terminal output (scene lists, written files, usage, refusals) — the one place
//  in MachmanRender that writes to stdout/stderr. Diagnostics still go to MachmanLogger.
//

import Foundation

enum Console {
	static func out(_ line: String) {
		FileHandle.standardOutput.write(Data((line + "\n").utf8))
	}

	static func err(_ line: String) {
		FileHandle.standardError.write(Data((line + "\n").utf8))
	}

	// Runs `body` with stderr going to `file`, then passes what it caught on to the real
	// stderr and returns it too: what AppKit logged while one scene drew (T26).
	static func capturingErrors<T>(
		in file: URL, _ body: () throws -> T
	) rethrows -> (result: T, errors: String) {
		fflush(stderr)
		let saved = dup(STDERR_FILENO)
		let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
		if fd >= 0 {
			dup2(fd, STDERR_FILENO)
			close(fd)
		}
		defer { try? FileManager.default.removeItem(at: file) }
		let result: T
		do {
			result = try body()
		} catch {
			restore(saved)
			throw error
		}
		restore(saved)
		let caught = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
		if !caught.isEmpty {
			FileHandle.standardError.write(Data(caught.utf8))
		}
		return (result, caught)
	}

	private static func restore(_ saved: Int32) {
		fflush(stderr)
		guard saved >= 0 else { return }
		dup2(saved, STDERR_FILENO)
		close(saved)
	}
}
