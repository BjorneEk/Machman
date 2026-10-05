//
//  ShellQuote.swift
//  MachmanAPI
//
//  Quoting for the shell commands Machman shows to copy (C26). A value that carries a VM
//  name — a key path, a share path — must reach the shell as ONE word whatever the name
//  holds: an apostrophe opened an unterminated quote in the pasted line, and a name like
//  x'; rm -rf ~; ' ran in the user's shell.
//

import Foundation

public enum ShellQuote {
	// POSIX single quotes: everything inside is literal, and an embedded ' closes the quote,
	// is escaped, and reopens it ('\'').
	public static func single(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
	}
}
