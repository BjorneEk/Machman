//
//  LabPrompts.swift
//  MachmanAPI
//
//  Under test mode no prompt is ever shown: each is logged and answered from the lab's answers
//  file (MACHMAN_LAB_ANSWERS), keyed by the prompt's stable id. The file is a JSON object,
//  re-read at every prompt, whose values are a button title or {"button": "<title>",
//  "holdSeconds": N}; a held answer keeps the prompt "up" that long, as a person reading it
//  would. A prompt the file doesn't list takes its cancel button, else its default.
//

import Foundation

// A prompt as the lab sees it: what an alert would say and offer.
public struct LabPrompt: Equatable, Sendable {
	public let id: String
	public let message: String
	public let info: String
	// The first is the default (Return).
	public let buttons: [String]
	public let cancelIndex: Int?

	public init(id: String, message: String, info: String, buttons: [String], cancelIndex: Int?) {
		self.id = id
		self.message = message
		self.info = info
		self.buttons = buttons
		self.cancelIndex = cancelIndex
	}

	// What a prompt the file doesn't list answers: its cancel button, else its default.
	public var defaultIndex: Int { cancelIndex ?? 0 }
}

public enum LabAnswers {
	public struct Decision: Equatable, Sendable {
		public let index: Int
		public let holdSeconds: Double
		// Whether the answers file named this prompt.
		public let listed: Bool
		// Why a listed answer was not taken, for the log.
		public let problem: String?

		public init(index: Int, holdSeconds: Double, listed: Bool, problem: String?) {
			self.index = index
			self.holdSeconds = holdSeconds
			self.listed = listed
			self.problem = problem
		}
	}

	// The longest a held answer keeps a prompt up.
	public static let maxHoldSeconds: Double = 600

	public static func decide(_ prompt: LabPrompt, answers: Data?) -> Decision {
		let fallback = Decision(
			index: prompt.defaultIndex, holdSeconds: 0, listed: false, problem: nil)
		guard let answers, !answers.isEmpty else { return fallback }
		guard let object = try? JSONSerialization.jsonObject(with: answers),
			let table = object as? [String: Any] else {
			return unreadable(prompt)
		}
		guard let value = table[prompt.id] else { return fallback }
		let title: String
		var hold: Double = 0
		if let plain = value as? String {
			title = plain
		} else if let held = value as? [String: Any], let button = held["button"] as? String {
			title = button
			if let seconds = held["holdSeconds"] {
				// JSON's true and false come back as NSNumbers too: not a duration.
				guard let number = seconds as? NSNumber,
					CFGetTypeID(number) != CFBooleanGetTypeID(),
					(0...maxHoldSeconds).contains(number.doubleValue) else {
					return unreadable(prompt)
				}
				hold = number.doubleValue
			}
		} else {
			return unreadable(prompt)
		}
		guard let index = prompt.buttons.firstIndex(of: title) else {
			return Decision(
				index: prompt.defaultIndex, holdSeconds: 0, listed: true,
				problem: "no button \u{201C}\(title)\u{201D}")
		}
		return Decision(index: index, holdSeconds: hold, listed: true, problem: nil)
	}

	private static func unreadable(_ prompt: LabPrompt) -> Decision {
		Decision(
			index: prompt.defaultIndex, holdSeconds: 0, listed: false,
			problem: "unreadable answers file")
	}

	// `test prompt <id>: "<message>" → <button>`, plus how it was answered.
	public static func logLine(_ prompt: LabPrompt, _ decision: Decision) -> String {
		let title = prompt.buttons.indices.contains(decision.index)
			? prompt.buttons[decision.index] : "(no button)"
		var line = "test prompt \(prompt.id): \"\(prompt.message)\" \u{2192} \(title)"
		if !decision.listed {
			line += " (not listed)"
		} else if decision.holdSeconds > 0 {
			line += " (held \(seconds(decision.holdSeconds)) s)"
		}
		return line
	}

	// Under test mode: the prompt's answer, logged, after any hold. nil outside test mode,
	// where the caller shows its real alert. Never touches AppKit.
	@MainActor
	public static func answerIfTesting(
		_ prompt: LabPrompt, lab: LabEnvironment? = .current
	) -> Int? {
		guard let lab else { return nil }
		let answers = lab.answersPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
		let decision = decide(prompt, answers: answers)
		if let problem = decision.problem {
			MachmanLogger.log(.passiveError, "test prompt \(prompt.id): \(problem)")
		}
		MachmanLogger.log(.log, logLine(prompt, decision))
		if decision.holdSeconds > 0 {
			hold(seconds: decision.holdSeconds)
		}
		return decision.index
	}

	// The mode NSAlert.runModal spins. AppKit makes it a common mode, so the main queue (every
	// main-actor job) drains in it as behind a shown alert; the lab's processes and the tests
	// are made to agree, then the loop waits on a timer, never polling.
	private static let modalPanelMode = RunLoop.Mode("NSModalPanelRunLoopMode")

	@MainActor
	private static func hold(seconds: Double) {
		let loop = RunLoop.current
		CFRunLoopAddCommonMode(
			loop.getCFRunLoop(), CFRunLoopMode(modalPanelMode.rawValue as CFString))
		let deadline = Date().addingTimeInterval(seconds)
		let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
		loop.add(timer, forMode: modalPanelMode)
		defer { timer.invalidate() }
		while Date() < deadline {
			_ = loop.run(mode: modalPanelMode, before: deadline)
		}
	}

	private static func seconds(_ value: Double) -> String {
		value == value.rounded() ? String(Int(value)) : String(value)
	}
}
