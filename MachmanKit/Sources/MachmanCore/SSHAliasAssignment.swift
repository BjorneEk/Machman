//
//  SSHAliasAssignment.swift
//  MachmanCore
//
//  Which VM answers to a default alias that two VM names map to — "dev copy" and "dev-copy"
//  both give dev-copy.machman (user decision 2026-10-01, amendment A-1a-1):
//
//  - A VM taking a name (create, Duplicate, Save as New VM, its own rename) or falling back
//    to its default alias yields: when its default is already some other VM's alias, it gets
//    the first free "<stem>-<n>.machman" and STORES it in its own ssh.alias. Stored aliases
//    are sticky — only the user changes them, so a delete, rename or create of one VM never
//    moves another VM's alias.
//  - Two VMs that already collide (named before this rule) are split by a fixed tie-break:
//    the name that needs no mapping keeps the base, then the older one, then name order.
//    The loser's suffix becomes its stored alias the next time its config is saved.
//
//  Every process resolves from the configs on disk, so the daemon, each vmhost and the
//  managed ~/.ssh file agree without asking each other. The scan is cached on the
//  library's directory listing and each config's identity, so it costs a stat per VM.
//

import Foundation
import MachmanAPI

enum SSHAliasAssignment {
	// One VM's hold on an alias: its directory name, the alias it stored (nil = its derived
	// default) and when it was created (the tie-break).
	struct Claim: Equatable {
		var name: String
		var stored: String?
		var created: Date
	}

	// The two keys a claim needs, decoded without VMConfig.load (which migrates and saves).
	private struct Facts: Decodable {
		struct SSH: Decodable { var alias: String? }
		var created: Date
		var ssh: SSH?
	}

	private static let cacheLock = NSLock()
	private static var cache: (library: String, stamp: [String], claims: [Claim])?

	// Every VM's claim in `library`, read from its config. Hidden entries (copy staging) and
	// directories without a readable config are not VMs.
	static func claims(inLibrary library: String) -> [Claim] {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(atPath: library) else { return [] }
		var stamp: [String] = []
		var names: [String] = []
		for entry in entries.sorted() where !entry.hasPrefix(".") {
			guard let attributes = try? fm.attributesOfItem(
				atPath: library + "/" + entry + "/config") else { continue }
			// Atomic saves replace the file, so the file number moves on every write.
			let modified = (attributes[.modificationDate] as? Date)?
				.timeIntervalSinceReferenceDate ?? 0
			let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
			let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
			stamp.append("\(entry)/\(file)/\(size)/\(modified)")
			names.append(entry)
		}
		cacheLock.lock()
		if let cache, cache.library == library, cache.stamp == stamp {
			cacheLock.unlock()
			return cache.claims
		}
		cacheLock.unlock()
		let claims = names.compactMap { name -> Claim? in
			let url = URL(fileURLWithPath: library + "/" + name + "/config")
			guard let data = try? Data(contentsOf: url),
				let facts = try? JSONDecoder().decode(Facts.self, from: data)
			else { return nil }
			return Claim(name: name, stored: facts.ssh?.alias, created: facts.created)
		}
		cacheLock.lock()
		cache = (library, stamp, claims)
		cacheLock.unlock()
		return claims
	}

	// The alias each VM answers to, by VM name. Stored aliases claim first, exactly as
	// stored; derived defaults follow in tie-break order, each taking its default when free
	// and the first free suffix otherwise. "Taken" ignores case (C31): ssh lowercases a
	// HostKeyAlias and looks up known_hosts case-insensitively, so Dev.machman and
	// dev.machman would share one host-key pin.
	static func resolve(_ claims: [Claim]) -> [String: String] {
		var result: [String: String] = [:]
		var taken = Set<String>()
		for claim in claims.sorted(by: { $0.name < $1.name }) {
			guard let stored = claim.stored else { continue }
			result[claim.name] = stored
			taken.insert(stored.lowercased())
		}
		let derived = claims.filter { $0.stored == nil }.sorted { a, b in
			let aPlain = needsNoMapping(a.name)
			let bPlain = needsNoMapping(b.name)
			if aPlain != bPlain { return aPlain }
			if a.created != b.created { return a.created < b.created }
			return a.name < b.name
		}
		for claim in derived {
			let alias = firstFree(SSHAliasRule.defaultAlias(for: claim.name), taken: taken)
			result[claim.name] = alias
			taken.insert(alias.lowercased())
		}
		return result
	}

	// The alias a VM taking `name` must store so it yields to every other VM — nil when its
	// default is free and it can keep following its name.
	static func yieldingAlias(for name: String, among others: [Claim]) -> String? {
		let taken = Set(resolve(others.filter { $0.name != name }).values)
		let base = SSHAliasRule.defaultAlias(for: name)
		return isTaken(base, in: taken) ? firstFree(base, taken: taken) : nil
	}

	// `base` itself, else "<stem>-2.machman", "<stem>-3.machman", … — the first not taken,
	// in any case.
	static func firstFree(_ base: String, taken: Set<String>) -> String {
		guard isTaken(base, in: taken) else { return base }
		let suffix = SSHAliasRule.defaultSuffix
		let stem = base.hasSuffix(suffix) ? String(base.dropLast(suffix.count)) : base
		let tail = base.hasSuffix(suffix) ? suffix : ""
		var n = 2
		while isTaken("\(stem)-\(n)\(tail)", in: taken) { n += 1 }
		return "\(stem)-\(n)\(tail)"
	}

	// Whether `alias` names the same host key as one in `taken` (case folded, C31).
	static func isTaken(_ alias: String, in taken: Set<String>) -> Bool {
		let folded = alias.lowercased()
		return taken.contains { $0.lowercased() == folded }
	}

	// Whether `alias` is a suffix this rule gave `name` (as opposed to one the user chose):
	// such an alias stands in for the default, so it goes when the VM takes a new name.
	static func isAssigned(_ alias: String, to name: String) -> Bool {
		let suffix = SSHAliasRule.defaultSuffix
		let stem = String(SSHAliasRule.defaultAlias(for: name).dropLast(suffix.count))
		guard alias.hasPrefix(stem + "-"), alias.hasSuffix(suffix),
			alias.count > stem.count + 1 + suffix.count else { return false }
		let number = alias.dropFirst(stem.count + 1).dropLast(suffix.count)
		return number.allSatisfy({ $0.isASCII && $0.isNumber }) && !number.hasPrefix("0")
			&& (Int(number) ?? 0) >= 2
	}

	private static func needsNoMapping(_ name: String) -> Bool {
		SSHAliasRule.isWellFormed(name + SSHAliasRule.defaultSuffix)
	}
}

extension VMConfig {
	// Every other VM's claim, from disk (this VM's own in-memory state is the current one).
	func otherAliasClaims() -> [SSHAliasAssignment.Claim] {
		SSHAliasAssignment.claims(inLibrary: machmanVMDir).filter { $0.name != name }
	}

	// The default alias this VM answers to while it stores none: its mapped name, unless an
	// older collision resolved otherwise.
	var resolvedDefaultAlias: String {
		let own = SSHAliasAssignment.Claim(name: name, stored: nil, created: created)
		return SSHAliasAssignment.resolve(otherAliasClaims() + [own])[name]
			?? SSHHostConfigWriter.defaultAlias(for: name)
	}

	// An assignment point: this VM is taking a name, or falling back to its default alias,
	// so it yields to every other VM. Stores the suffix when its default is taken; the
	// caller saves.
	func assignDefaultAliasIfTaken() {
		guard ssh?.alias == nil,
			let alias = SSHAliasAssignment.yieldingAlias(for: name, among: otherAliasClaims())
		else { return }
		var state = ssh ?? SSHConfig()
		state.alias = alias
		ssh = state
	}

	// Forget the alias (an identity reset, or an assigned suffix when the VM takes a new
	// name). An alias-only state goes entirely: it never meant SSH was set up here.
	func dropAlias() {
		guard var state = ssh else { return }
		if state.isAliasOnly {
			ssh = nil
		} else {
			state.alias = nil
			ssh = state
		}
	}

	// Called by every save: an older collision's suffix, served so far by resolution
	// alone, becomes this VM's stored alias, so a later change to the other VM can't move
	// it. Nothing to do for a VM that stores an alias or keeps its plain default. Every save
	// is also where an alias move becomes real, so the session tabs' pin follows it here.
	func persistResolvedDefaultAlias() {
		defer { SSHSetupInstaller.repinIfAliasMoved(for: self) }
		guard ssh?.alias == nil else { return }
		let resolved = resolvedDefaultAlias
		guard resolved != SSHHostConfigWriter.defaultAlias(for: name) else { return }
		var state = ssh ?? SSHConfig()
		state.alias = resolved
		ssh = state
	}
}
