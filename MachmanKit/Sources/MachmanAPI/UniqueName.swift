//
//  UniqueName.swift
//  MachmanAPI
//
//  The one numbering for every name Machman suggests (a duplicate's “<VM> copy”, a saved safe
//  run's “<VM> saved”, a new or duplicated terminal profile): the base while it is free, else
//  “<base> 2”, “<base> 3”, …, the first one nothing has taken.
//

import Foundation

public enum UniqueName {
	public static func numbered(_ base: String, isTaken: (String) -> Bool) -> String {
		guard isTaken(base) else { return base }
		var n = 2
		while isTaken("\(base) \(n)") { n += 1 }
		return "\(base) \(n)"
	}
}
