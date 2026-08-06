//
//  Wire.swift
//  MachmanAPI
//
//  The one true JSON configuration for everything that crosses the API. Dates are ISO 8601,
//  keys are sorted (deterministic output for fixtures and debugging), slashes unescaped
//  (readable paths), and output is single-line — the phase-2 transport is newline-framed.
//

import Foundation

public enum MachmanWire {
	public static func encoder() -> JSONEncoder {
		let e = JSONEncoder()
		e.dateEncodingStrategy = .iso8601
		e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return e
	}

	public static func decoder() -> JSONDecoder {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		return d
	}
}
