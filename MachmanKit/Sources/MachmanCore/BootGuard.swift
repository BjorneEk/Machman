//
//  BootGuard.swift
//  MachmanCore
//
//  The one cross-VM boot guard (PR15): no VM boots with a MAC another running or starting VM
//  uses (one of them would lose networking), and none attaches a writable disk file another
//  one has attached (C5: two writers corrupt it). Pure over what the caller knows of the
//  others, so the router's start and every other boot path ask the same question — Start
//  at login among them (E38), read from the configs on disk.
//

import Foundation
import MachmanAPI

enum BootGuard {
	// The VM about to boot. `order`: its start claim's, when it has one — among starts, the
	// earlier claim wins a MAC, so two same-MAC starts never both fail.
	struct Candidate {
		let name: String
		var mac: String?
		var disks: Set<String> = []
		var order: Int?
	}

	// Another VM that runs or is starting, and what it holds.
	struct Other {
		enum Role: Equatable {
			case running
			case starting(order: Int)
			// It starts at login, as the candidate is about to (C8).
			case autostart
		}

		let name: String
		let role: Role
		let mac: String?
		// The writable disk files it has attached for sure, and the ones it may have: an entry
		// whose flag can't tell (a host's disabled entry it may have started with).
		var attached: Set<String> = []
		var mayHaveAttached: Set<String> = []

		// Whether the guard weighs this one against `candidate`: a writable disk file it has or
		// may have attached, or (`mac`) the MAC. A start waits out such a VM whose run is over
		// before it asks (E71).
		func shares(with candidate: Candidate, mac: Bool) -> Bool {
			guard name != candidate.name else { return false }
			if !candidate.disks.isDisjoint(with: attached.union(mayHaveAttached)) { return true }
			return mac && candidate.mac != nil && self.mac == candidate.mac
		}
	}

	// `force` overrides it: lost networking recovers.
	static func checkMAC(_ candidate: Candidate, among others: [Other]) throws {
		guard let mac = candidate.mac else { return }
		let name = candidate.name
		let mine = candidate.order ?? Int.max
		let sharers = others.filter { $0.name != name && $0.mac == mac }
		if let atLogin = sharers.first(where: { $0.role == .autostart }) {
			throw MachmanError(
				code: .invalidState,
				message: "\(atLogin.name) also starts at login with MAC address \(mac) — "
					+ "regenerate the MAC address of one of them")
		}
		if let running = sharers.first(where: { $0.role == .running }) {
			throw MachmanError(
				code: .macConflict,
				message: "\(name) and the running VM \u{201C}\(running.name)\u{201D} "
					+ "share MAC address \(mac), so one of them would lose networking")
		}
		let earlier = sharers.compactMap { other -> (Other, Int)? in
			guard case .starting(let order) = other.role, order < mine else { return nil }
			return (other, order)
		}.min { $0.1 < $1.1 }?.0
		if let earlier {
			throw MachmanError(
				code: .macConflict,
				message: "\(name) and \u{201C}\(earlier.name)\u{201D}, which is starting, share "
					+ "MAC address \(mac), so one of them would lose networking")
		}
	}

	// Never overridden: a disk written by two VMs does not recover. Isos attach read-only and
	// never count. The first sharer by name, and its first shared file by path.
	static func checkDisks(_ candidate: Candidate, among others: [Other]) throws {
		guard !candidate.disks.isEmpty else { return }
		let name = candidate.name
		for other in others.sorted(by: { $0.name < $1.name }) where other.name != name {
			let theirs = other.attached.union(other.mayHaveAttached)
			guard let file = candidate.disks.intersection(theirs).sorted().first else { continue }
			let disk = (file as NSString).lastPathComponent
			if other.role == .autostart {
				throw MachmanError(
					code: .invalidState,
					message: "\(other.name) also starts at login with \(disk) attached — turn "
						+ "off Start at login for one of them")
			}
			throw MachmanError(
				code: .invalidState,
				message: (other.attached.contains(file)
					? "\(other.name) is running with \(disk) attached"
					: "\(other.name) may still have \(disk) attached")
					+ " — stop \(other.name) before starting \(name)")
		}
	}

	// MARK: - Configs on disk

	// A VM's config as its file says now, decoded only: never migrated or saved, since
	// another process may own it (a vmhost saves its VM's config whole). nil when unreadable.
	// Its paths resolve through machmanVMDir, which every caller has pointed at `library`.
	static func peekConfig(name: String, library: String) -> VMConfig? {
		guard let data = FileManager.default.contents(atPath: library + "/" + name + "/config"),
			let config = try? JSONDecoder().decode(VMConfig.self, from: data) else { return nil }
		config.name = name   // the directory name is authoritative (VMConfig.load)
		return config
	}

	// Every VM folder in the library whose config reads.
	static func libraryConfigs(_ library: String) -> [VMConfig] {
		let entries = (try? FileManager.default.contentsOfDirectory(atPath: library)) ?? []
		return entries.filter { !$0.hasPrefix(".") }.sorted()
			.compactMap { peekConfig(name: $0, library: library) }
	}

	// C8: turning Start at login on beside another VM that starts at login and shares a
	// writable disk file or the MAC — at the next login both would boot. A VM that already
	// starts at login is let be, so its other run defaults stay editable.
	static func autostartConflict(turningOn name: String, library: String) -> MachmanError? {
		guard let mine = peekConfig(name: name, library: library),
			!mine.startPolicy.autostart else { return nil }
		let others = libraryConfigs(library)
			.filter { $0.name != name && $0.startPolicy.autostart }
			.map {
				Other(
					name: $0.name, role: .autostart, mac: $0.macAddress,
					attached: $0.writableDiskFiles)
			}
		return refusal(Candidate(name: name, mac: mine.macAddress, disks: mine.writableDiskFiles),
			among: others)
	}

	// C8's login half: the vmhost about to boot its VM at login, which sees only that VM,
	// looks for a library VM sharing a writable disk file or the MAC whose vmhost answers
	// on its socket — running, or about to. What that one attached can't be told from here,
	// so each of its entries counts. claimLoginBoot asks it after the login locks.
	static func runningSharerConflict(
		vm name: String, library: String, runtimeDir: String, isLive: (String) -> Bool
	) -> MachmanError? {
		guard let mine = peekConfig(name: name, library: library) else { return nil }
		let others = libraryConfigs(library)
			.filter {
				$0.name != name
					&& isLive(MachmanPaths.vmSocketPath(vm: $0.name, runtimeDir: runtimeDir))
			}
			.map {
				Other(
					name: $0.name, role: .running, mac: $0.macAddress,
					mayHaveAttached: $0.everyWritableDiskFile)
			}
		return refusal(Candidate(name: name, mac: mine.macAddress, disks: mine.writableDiskFiles),
			among: others)
	}

	// MARK: - Login boots (E54)

	// What a login boot holds for its run: an exclusive flock on a lock file in the runtime dir
	// per writable disk file and per MAC it boots with. Closed with the process, or by
	// release().
	final class LoginLocks {
		private var descriptors: [Int32]

		fileprivate init(_ descriptors: [Int32]) {
			self.descriptors = descriptors
		}

		func release() {
			descriptors.forEach { close($0) }
			descriptors = []
		}

		// The boot went through: a sharer waiting for these locks stops waiting (review F2).
		// The mark names this process, so one left behind by a holder that's gone counts
		// for nothing.
		func markBooted() {
			let mark = Array("booted \(getpid())\n".utf8)
			for fd in descriptors {
				_ = ftruncate(fd, 0)
				_ = pwrite(fd, mark, mark.count, 0)
			}
		}
	}

	// How long a login boot waits for a lock a sharer holds (review F2): `polls` pauses. A
	// holder still deciding boots or gives up within it — a start that has done neither in
	// two minutes counts as booting.
	struct LoginWait {
		var polls: Int
		var pause: () -> Void

		static let standard = LoginWait(polls: 480) { usleep(250_000) }
	}

	// What two login boots must not share, by its lock's key.
	enum LoginResource: Equatable {
		case disk(String)
		case mac(String)

		var key: String {
			switch self {
			case .disk(let file): return "disk:" + file
			case .mac(let mac): return "mac:" + mac.lowercased()
			}
		}
	}

	// C8's login half, decided before the vmhost binds its socket (E54). Login vmhosts that
	// each bound first saw one another's fresh socket and all refused, so the one lock per
	// shared resource decides: a sharer holding one boots, or runs, at this login. A lock a
	// sharer holds is waited for while that sharer still decides (`wait`): one that gives up
	// frees it. The locks are taken in one order (disks by path, then the MAC), so no two
	// waiters wait on each other. Then the live-socket check, for a sharer the agent started
	// (it takes no lock). The locks on success, to hold for the run; else why not.
	static func claimLoginBoot(
		vm name: String, library: String, runtimeDir: String, isLive: (String) -> Bool,
		wait: LoginWait = .standard
	) -> Result<LoginLocks, MachmanError> {
		guard let mine = peekConfig(name: name, library: library) else {
			return .success(LoginLocks([]))   // its start says why
		}
		_ = ensureDirectory(runtimeDir)
		var resources = mine.writableDiskFiles.sorted().map(LoginResource.disk)
		if let mac = mine.macAddress { resources.append(.mac(mac)) }
		var held: [Int32] = []
		for resource in resources {
			let path = runtimeDir + "/login-" + MachmanPaths.shortHash(resource.key) + ".lock"
			let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
			guard fd >= 0 else {
				let reason = String(cString: strerror(errno))
				MachmanLogger.log(.passiveWarning,
					"\(name) boots without the login lock \(path): \(reason)")
				continue
			}
			if takeLock(fd, wait: wait) {
				_ = ftruncate(fd, 0)   // an earlier holder's mark goes
				held.append(fd)
				continue
			}
			close(fd)
			held.forEach { close($0) }
			return .failure(lockedRefusal(mine, resource, library: library))
		}
		if let conflict = runningSharerConflict(
			vm: name, library: library, runtimeDir: runtimeDir, isLive: isLive) {
			held.forEach { close($0) }
			return .failure(conflict)
		}
		return .success(LoginLocks(held))
	}

	// The lock on `fd`, waited for while its holder still decides: false once the holder marked
	// it booted, or when the wait ran out.
	private static func takeLock(_ fd: Int32, wait: LoginWait) -> Bool {
		var polls = 0
		while flock(fd, LOCK_EX | LOCK_NB) != 0 {
			guard polls < wait.polls, !holderBooted(fd) else { return false }
			wait.pause()
			polls += 1
		}
		return true
	}

	// The holder's mark ("booted <pid>"), from a holder that still runs.
	private static func holderBooted(_ fd: Int32) -> Bool {
		var bytes = [UInt8](repeating: 0, count: 64)
		let count = pread(fd, &bytes, bytes.count, 0)
		guard count > 0 else { return false }
		let mark = String(decoding: bytes[0..<count], as: UTF8.self)
		guard mark.hasPrefix("booted "),
			let pid = pid_t(mark.dropFirst(7).prefix { $0.isNumber }) else { return false }
		return kill(pid, 0) == 0 || errno == EPERM
	}

	// A lock doesn't say who holds it: the refusal names the library's VM sharing the
	// resource (one that starts at login first), as running — it runs, or is about to.
	private static func lockedRefusal(
		_ mine: VMConfig, _ resource: LoginResource, library: String
	) -> MachmanError {
		let sharers = libraryConfigs(library).filter { other in
			guard other.name != mine.name else { return false }
			switch resource {
			case .disk(let file): return other.everyWritableDiskFile.contains(file)
			case .mac: return other.macAddress?.lowercased() == mine.macAddress?.lowercased()
			}
		}
		let holder = (sharers.first { $0.startPolicy.autostart } ?? sharers.first)?.name
			?? "another VM"
		let candidate: Candidate
		let other: Other
		switch resource {
		case .disk(let file):
			candidate = Candidate(name: mine.name, disks: [file])
			other = Other(name: holder, role: .running, mac: nil, attached: [file])
		case .mac:
			candidate = Candidate(name: mine.name, mac: mine.macAddress)
			other = Other(name: holder, role: .running, mac: mine.macAddress)
		}
		return refusal(candidate, among: [other]) ?? MachmanError(
			code: .invalidState, message: "\(holder) holds what \(mine.name) boots with")
	}

	private static func refusal(_ candidate: Candidate, among others: [Other]) -> MachmanError? {
		do {
			try checkDisks(candidate, among: others)
			try checkMAC(candidate, among: others)
		} catch let error as MachmanError {
			return error
		} catch {
			return nil
		}
		return nil
	}
}
