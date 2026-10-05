//
//  SSHConfigQuote.swift
//  MachmanAPI
//
//  One argument of an ssh_config option, quoted the way OpenSSH's own parser reads it —
//  the managed ~/.ssh file the daemon writes and the -o options the session tabs pass take
//  it from here (C28). OpenSSH takes \" and \\ inside quotes, and the path options
//  (IdentityFile, UserKnownHostsFile) expand %-tokens, so a literal % doubles: a VM named
//  "50% off" made ssh die ("percent_dollar_expand: failed"), one named dev"x made it refuse
//  the line ("invalid quotes").
//

import Foundation

public enum SSHConfigQuote {
	// nil for control characters: no quoting carries a line break.
	public static func argument(_ value: String, expandsTokens: Bool) -> String? {
		guard !NameRule.hasControlCharacters(value) else { return nil }
		var escaped = value
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		if expandsTokens {
			escaped = escaped.replacingOccurrences(of: "%", with: "%%")
		}
		return "\"" + escaped + "\""
	}
}
