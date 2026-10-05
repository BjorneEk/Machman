//
//  main.swift
//  hostwatch
//
//  The lab's host-quiet audit helper: a plain CLI, compiled by scripts/lab/audit/build.sh and
//  never part of the package. Subcommands: watch | snapshot | diff | window-probe | logprobe.
//  Results go to files named by flags (or stdout), never to stderr. It never creates an
//  NSApplication outside window-probe, never reads pasteboard contents or window titles,
//  and never touches anything under <home>/.machman.
//

import Foundation

/// The argument after `flag`, if any.
func value(_ flag: String, in args: [String]) -> String? {
	guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
	return args[index + 1]
}

/// The argument after every occurrence of `flag`.
func values(_ flag: String, in args: [String]) -> [String] {
	var found: [String] = []
	for (index, argument) in args.enumerated() where argument == flag && index + 1 < args.count {
		found.append(args[index + 1])
	}
	return found
}

/// Writes `lines` to `path`, or to standard output when no path is given.
func emit(_ lines: [String], to path: String?) {
	let text = lines.map { $0 + "\n" }.joined()
	if let path {
		try? text.write(toFile: path, atomically: true, encoding: .utf8)
	} else {
		FileHandle.standardOutput.write(Data(text.utf8))
	}
}

let arguments = Array(CommandLine.arguments.dropFirst())
let rest = Array(arguments.dropFirst())
switch arguments.first {
case "watch": runWatch(rest)
case "snapshot": runSnapshot(rest)
case "diff": runDiff(rest)
case "window-probe": runWindowProbe(rest)
case "logprobe": runLogProbe(rest)
default: exit(64)
}
