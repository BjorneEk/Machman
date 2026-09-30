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
}
