//
//  HostedVM.swift
//  MachmanCore
//
//  What the router knows about one vmhost: its identity, fixed at spawn or adopt, and the
//  HostedVM record the host table keeps while the host serves its VM. Also the process a
//  spawn launched, as a protocol a router test can stand in for.
//

import Foundation
import AppKit
import MachmanAPI
import MachmanClient

// The vmhost process a spawn launched: NSRunningApplication for real, a stand-in in router
// tests, which can't launch the app (E62, E64).
protocol VMHostApp: AnyObject {
	var processIdentifier: pid_t { get }
	var isTerminated: Bool { get }
	@discardableResult func forceTerminate() -> Bool
	// Calls `handler` once the process has exited, until the watch is invalidated.
	func watchTermination(_ handler: @escaping @Sendable () -> Void) -> VMHostAppWatch
}

protocol VMHostAppWatch: AnyObject {
	func invalidate()
}

extension NSKeyValueObservation: VMHostAppWatch {}

extension NSRunningApplication: VMHostApp {
	func watchTermination(_ handler: @escaping @Sendable () -> Void) -> VMHostAppWatch {
		observe(\.isTerminated, options: [.new]) { app, _ in
			if app.isTerminated { handler() }
		}
	}
}

extension RoutingMachman {
	// A start's vmhost while the start runs (E64): the launched app from its launch, the host
	// the start is handed to once it is reached (spawned, or idle and adopted), whether a
	// Force Stop or End Process ended it, and the probe that watches a spawned one.
	final class StartInFlight {
		var app: VMHostApp?
		var host: HostedVM?
		var canceled = false
		var watch: Task<Void, Never>?

		var canEnd: Bool { app != nil || host != nil }
	}

	// Everything the daemon knows about one vmhost, fixed at spawn/adopt time. Stored, never
	// recomputed: hostGone unlinks identity.socketPath and closures capture identity.id, so
	// both survive any re-keying of `hosted` (safe mode re-keys on save-as-new, and re-points
	// socketPath when the vmhost moved its socket to the saved VM's path).
	struct HostIdentity {
		let id: UUID
		var name: String
		var socketPath: String
		var isSafe = false           // a safe-mode run (vm.start {safe:true})
		var shadowRoot: String?      // that safe run's shadow copy (SafeRun)
		// The MAC the guest is actually using — captured at spawn from the config, at adopt
		// from the host's own reply (they can differ after a safe-save promotion).
		var macInUse: String?
		// The library a safe run saves into: its vmhost's --library, set at spawn. nil for a
		// re-attached run, whose vmhost an earlier daemon handed this daemon's own.
		var library: String?
	}

	final class HostedVM {
		// var: safe-mode re-attach (startup sweep) and safeSave re-keying mutate its fields.
		// Safe because every closure captures identity.id (a value), never the struct.
		var identity: HostIdentity
		// var: a dropped connection to a live host is replaced (E8).
		var client: RemoteMachman
		var reconnectTask: Task<Void, Never>?
		// The spawned standalone app; nil for adopted hosts (their only death detector is the
		// socket disconnect, same as before). deathWatch routes isTerminated to hostGone —
		// invalidate it BEFORE forceTerminate on failure paths so a cleanup kill can't
		// re-enter (hostGone is idempotent anyway; this keeps the sequence obviously correct).
		let app: VMHostApp?
		var deathWatch: VMHostAppWatch?
		var eventTask: Task<Void, Never>?
		// Done once the host has this daemon's subscription (E9): a start is forwarded only
		// after it, so nothing the boot emits goes to a bus nobody hears.
		var eventsSubscribed: Task<Void, Never>?
		// SSH address discovery (1.0.5): daemon memory only, rebuilt after restarts by
		// the adopt path; served as a VMInfo overlay like safeRun.
		var sshAnswer: SSHDiscovery.Answer?
		var sshDiscoveryTask: Task<Void, Never>?
		// …and whether the guest's sshd actually answers (1.0.6). Also daemon memory:
		// it describes THIS run, so a stopped VM has no reachability at all.
		var sshReach: SSHInfo.Reachability = .unknown
		var sshReachDetail: String?
		var sshReadySince: Date?
		// E20: the host's last vm.get answer — what clients see while it misses its answer
		// deadline, marked unresponsive — and the watcher that notices it answering again.
		var lastAnswer: VMInfo? {
			didSet { if let state = lastAnswer?.state { lastState = state } }
		}
		// The VM's state as the host last told it: a stateChanged event or an answer (V7:
		// the agent's quit asks whether VMs run, not whether hosts exist).
		var lastState: VMState?
		var unresponsive = false
		var recoveryTask: Task<Void, Never>?
		// Whether this host ever ran its VM (E12): an idle host from a start whose forward
		// never happened can take a new start; one whose run stopped is exiting.
		var sawRun = false
		// A host that ran its VM and since told it stopped (or failed) is exiting: after its
		// stop flush, and after any import it still drains (E34). Clients already list the VM
		// stopped (E52).
		var exitingAfterRun: Bool {
			sawRun && (lastState == .stopped || lastState == .error)
		}

		// A start this daemon forwarded succeeded: the VM runs, whether or not its running
		// event got here first (a later event still moves lastState on).
		func markStarted() {
			sawRun = true
			lastState = .running
		}
		// The disk files a start this daemon made left unattached (its disabled entries), or
		// nil for a start it did not make (an adopted host). The run attached every other
		// entry, whatever the flags say now: vm.setEnabled edits a running VM's config but
		// detaches nothing (C5). These paths never move — Save as New VM moves only what
		// the run attached — so they survive its re-keying.
		var unattachedDisks: Set<String>?

		// What the vmhost answered hello with: "<its own bundle version>-vmhost" since 1.0.12;
		// an older one echoed the spawning daemon's version, or "dev" under a launch agent.
		var version: String { client.hello.daemonVersion }

		init(
			identity: HostIdentity, client: RemoteMachman,
			app: VMHostApp?, deathWatch: VMHostAppWatch?
		) {
			self.identity = identity
			self.client = client
			self.app = app
			self.deathWatch = deathWatch
		}
	}
}
