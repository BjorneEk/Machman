//
//  MachmanClock.swift
//  MachmanUI
//
//  What "now" is for text that counts time: an uptime, “1 hour ago”, a download's time left,
//  when an activity entry or a session started. The wall clock, except in the offscreen
//  renders, which pin it to one instant so a scene draws the same text on every run (Q16).
//  Timers, deadlines and log stamps keep reading the real clock.
//

import Foundation

public enum MachmanClock {
	// Set once, before anything reads it (the render tool's start); never by tests.
	nonisolated(unsafe) public static var now: @Sendable () -> Date = { Date() }
}
