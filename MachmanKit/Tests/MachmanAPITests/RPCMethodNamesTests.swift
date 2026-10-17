//
//  RPCMethodNamesTests.swift
//  MachmanAPITests
//
//  The wire's method names, frozen (A16): the Swift client and server share RPCMethod, so a
//  renamed case compiles and passes every other suite while it breaks machman-smoke.py, every
//  non-Swift client and every old/new mix. A rename fails here; an addition fails until it is
//  added to the table (a decision, not an accident) and to docs/ipc-protocol.md.
//

import Foundation
import Testing
import MachmanAPI
import MachmanTestSupport

// L1: unit + lint (repo files).
struct RPCMethodNamesTests {
	// Every method the protocol has served, by its Swift case. Extend, never change.
	static let frozen: [String: String] = [
		"hello": "machman.hello",
		"hostCapabilities": "host.capabilities",
		"vmList": "vm.list",
		"vmGet": "vm.get",
		"vmCreate": "vm.create",
		"vmDelete": "vm.delete",
		"vmRename": "vm.rename",
		"vmCopy": "vm.copy",
		"setHardware": "vm.setHardware",
		"regenerateMAC": "vm.regenerateMAC",
		"diskAdd": "vm.disk.add",
		"diskRemove": "vm.disk.remove",
		"diskImport": "vm.disk.import",
		"diskPromote": "vm.disk.promote",
		"mountAdd": "vm.mount.add",
		"mountRemove": "vm.mount.remove",
		"setKernelBoot": "vm.boot.setKernel",
		"updateKernelSettings": "vm.boot.kernelSettings",
		"kernelPromote": "vm.kernel.promote",
		"kernelDelete": "vm.kernel.delete",
		"setStartPolicy": "vm.setStartPolicy",
		"setSafety": "vm.setSafety",
		"start": "vm.start",
		"stop": "vm.stop",
		"safeSave": "vm.safeSave",
		"windowOpen": "vm.window.open",
		"windowClose": "vm.window.close",
		"consoleAdd": "vm.console.add",
		"consoleRemove": "vm.console.remove",
		"uartAdd": "vm.uart.add",
		"uartRemove": "vm.uart.remove",
		"serialSetLogging": "vm.serial.setLogging",
		"preview": "vm.preview",
		"installStart": "vm.install.start",
		"installCancel": "vm.install.cancel",
		"installPhase": "vm.install.phase",
		"deviceAdd": "vm.device.add",
		"deviceRemove": "vm.device.remove",
		"deviceUpdate": "vm.device.update",
		"setEnabled": "vm.setEnabled",
		"kernelSetOverride": "vm.kernel.setOverride",
		"diskResize": "vm.disk.resize",
		"diskRename": "vm.disk.rename",
		"mountSetTag": "vm.mount.setTag",
		"kernelRename": "vm.kernel.rename",
		"sshSet": "vm.ssh.set",
		"sshRefresh": "vm.ssh.refresh",
		"sshReset": "vm.ssh.reset",
		"mountSetKind": "vm.mount.setKind",
		"setupReset": "vm.setup.reset",
		"setupServe": "vm.setup.serve",
		"setupPin": "vm.setup.pin",
		"setupScriptsImport": "host.setupScripts.import",
		"hostOperations": "host.operations",
		"operationCancel": "op.cancel",
		"installRosetta": "host.installRosetta",
		"eventsSubscribe": "events.subscribe",
		"daemonRetire": "daemon.retire",
		"processEnd": "vm.process.end",
		"kernelClear": "vm.kernel.clear",
		"event": "event",
	]

	// The enum's cases as RPCMethods.swift spells them: `case <name> = "<raw>"`.
	static func declared() throws -> [String: String] {
		let source = try RepoFiles.text("MachmanKit/Sources/MachmanAPI/RPCMethods.swift")
		let body = try #require(source.components(separatedBy: "public enum RPCMethod:").dropFirst()
			.first?.components(separatedBy: "\n}").first)
		let pattern = try NSRegularExpression(pattern: #"^\s*case (\w+) = "([^"]+)""#,
			options: .anchorsMatchLines)
		var found: [String: String] = [:]
		for match in pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
			let name = String(body[Range(match.range(at: 1), in: body)!])
			found[name] = String(body[Range(match.range(at: 2), in: body)!])
		}
		return found
	}

	@Test("A16: every wire method keeps its frozen name")
	func namesAreFrozen() throws {
		for (name, raw) in Self.frozen {
			#expect(RPCMethod(rawValue: raw) != nil, "\(name) no longer answers to \(raw)")
		}
		let declared = try Self.declared()
		#expect(declared.count > 50, "the lint found \(declared.count) cases")
		for (name, raw) in declared where Self.frozen[name] != raw {
			let why = "a rename breaks old clients; an addition belongs in the table and the doc"
			Issue.record("RPCMethod.\(name) = \"\(raw)\" is not in the frozen table: \(why)")
		}
		for name in Self.frozen.keys where declared[name] == nil {
			Issue.record("RPCMethod.\(name) was removed or renamed")
		}
	}

	@Test("A16: docs/ipc-protocol.md lists every request method")
	func protocolDocListsEveryMethod() throws {
		let doc = try RepoFiles.text("docs/ipc-protocol.md")
		for raw in Self.frozen.values where raw != "event" {
			#expect(doc.contains("| `\(raw)` |"), "\(raw) has no row in the Methods table")
		}
		#expect(doc.contains("\"event\""), "the event notification is undocumented")
	}
}
