import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

// End-to-end wire test: MachmanServer and RemoteMachman talking over a real unix socket in
// this process, against an in-memory stub engine. Validates dispatch, DTO round-trips, error
// mapping, and event notifications without touching any data dir.

struct LoopbackTests {

	@Test @MainActor func sshSetRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "ssh-loop")

		let updated = try await client.setSSH(
			vm: "Debian", integrationEnabled: true, reverseApproved: nil, alias: "dev")
		#expect(updated.ssh?.integrationEnabled == true)
		#expect(updated.ssh?.reverseState == SSHInfo.ReverseState.none)
		#expect(updated.ssh?.alias == "dev")
		try await client.refreshSSH(vm: "Debian")
		let cleared = try await client.resetSSH(vm: "Debian")
		#expect(cleared.ssh == nil)
	}

	@Test @MainActor func mountKindAndSetupResetRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var info = StubMachman.makeInfo("Debian")
		info.setup = GuestSetupInfo(installed: true, guestOS: "debian")
		stub.vms["Debian"] = info
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "setup-loop")

		try await client.addMount(vm: "Debian", path: "/x/docs", tag: "docs", kind: nil)
		let mountID = try await client.vm(named: "Debian").mounts.last?.id ?? ""
		let switched = try await client.setMountKind(
			vm: "Debian", mountID: mountID, kind: MountKind.sshfs)
		#expect(switched.mounts.last?.kind == MountKind.sshfs)

		#expect(try await client.vm(named: "Debian").setup?.installed == true)

		// vm.setup.serve rides the wire with its flag intact, both ways.
		_ = try await client.setSetupServed(vm: "Debian", serve: false)
		#expect(stub.served["Debian"] == false)
		_ = try await client.setSetupServed(vm: "Debian", serve: true)
		#expect(stub.served["Debian"] == true)

		let cleared = try await client.resetSetup(vm: "Debian")
		#expect(cleared.setup == nil)
	}

	@Test @MainActor func wireRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "loopback")
		#expect(client.hello.apiVersion == MachmanProtocol.apiVersion)
		#expect(client.hello.daemonVersion == "test")

		// Events: subscribe first so mutations below arrive as notifications.
		let events = await client.events()
		var received: [VMEvent] = []
		let collector = Task {
			for await event in events {
				received.append(event)
				if received.count >= 2 { break }
			}
		}

		// Round-trips.
		let caps = try await client.hostCapabilities()
		#expect(caps.freeDiskBytes == 42)
		let list = try await client.listVMs()
		#expect(list.map(\.name) == ["Debian"])

		try await client.start(vm: "Debian", options: StartOptions(openWindow: false))
		let started = try await client.vm(named: "Debian")
		#expect(started.state == .running)
		#expect(!started.windowOpen)

		let preview = try await client.preview(vm: "Debian", maxWidth: nil)
		#expect(preview == Data([0xFF, 0xD8, 0xFF]))

		try await client.stop(vm: "Debian", mode: .force)
		#expect(try await client.preview(vm: "Debian", maxWidth: nil) == nil)

		// Application errors round-trip with their code.
		do {
			_ = try await client.vm(named: "nope")
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
			#expect(error.message.contains("nope"))
		}

		// The two state changes must have arrived, in order.
		await collector.value
		#expect(received == [
			.stateChanged(vm: "Debian", state: .running),
			.stateChanged(vm: "Debian", state: .stopped),
		])

		await client.disconnect()
	}

	@Test @MainActor func regenerateMACRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-mac-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "mac")
		let updated = try await client.regenerateMAC(vm: "Debian")
		#expect(updated.macAddress == "0a:0a:0a:0a:0a:0a")
		#expect(try await client.vm(named: "Debian").macAddress == "0a:0a:0a:0a:0a:0a")
		await client.disconnect()
	}

	@Test @MainActor func serialPortsRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-ser-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "serial")
		try await client.addConsolePort(vm: "Debian")
		try await client.addUartPort(vm: "Debian")
		try await client.addUartPort(vm: "Debian")
		let info = try await client.vm(named: "Debian")
		#expect(info.consolePorts?.count == 1)
		#expect(info.uartPorts?.count == 2)
		#expect(info.uartPorts?[1].guestDevice == "ttyAMA1")

		try await client.setSerialLogging(
			vm: "Debian", kind: .uart, index: 0,
			config: SerialLogConfig(mode: .continuous, maxBytes: 4096))
		let after = try await client.vm(named: "Debian")
		#expect(after.uartPorts?[0].logging == SerialLogConfig(mode: .continuous, maxBytes: 4096))

		try await client.removeUartPort(vm: "Debian")
		#expect(try await client.vm(named: "Debian").uartPorts?.count == 1)

		// Removing past empty, and an unknown index, carry their codes over the wire.
		try await client.removeUartPort(vm: "Debian")
		do {
			try await client.removeUartPort(vm: "Debian")
			Issue.record("expected invalidArgument")
		} catch let error as MachmanError {
			#expect(error.code == .invalidArgument)
		}
		do {
			try await client.setSerialLogging(
				vm: "Debian", kind: .console, index: 9, config: SerialLogConfig())
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
		}
		await client.disconnect()
	}

	@Test @MainActor func kernelPromoteRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-krn-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "krn")
		let promoted = try await client.promoteKernelFile(
			vm: "Debian", role: .kernel, sourcePath: "/tmp/vmlinuz", tag: "janus")
		#expect(promoted.boot.kernel?.kernelPath.hasSuffix("/janus/vmlinuz") == true)
		let owned = try #require(promoted.boot.ownedKernels?.first)
		#expect(owned.role == .kernel && owned.tag == "janus" && owned.fileName == "vmlinuz")

		let after = try await client.deleteKernelFile(vm: "Debian", path: owned.path)
		#expect(after.boot.ownedKernels?.isEmpty == true)
		await client.disconnect()
	}

	@Test @MainActor func setStartPolicyRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-pol-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "pol")
		let policy = StartPolicy(windowed: false, safe: true, autostart: true)
		try await client.setStartPolicy(vm: "Debian", policy: policy)
		#expect(try await client.vm(named: "Debian").startPolicy == policy)
		await client.disconnect()
	}

	@Test @MainActor func copyRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-copy-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "copy")
		let copy = try await client.copyVM(
			vm: "Debian", newName: nil, diskIDs: nil, regenerateMAC: true)
		#expect(copy.name == "Debian copy")
		#expect(try await client.listVMs().map(\.name) == ["Debian", "Debian copy"])

		do {
			_ = try await client.copyVM(
				vm: "Debian", newName: "Debian copy", diskIDs: nil, regenerateMAC: true)
			Issue.record("expected alreadyExists")
		} catch let error as MachmanError {
			#expect(error.code == .alreadyExists)
		}
		await client.disconnect()
	}

	@Test @MainActor func setSafetyRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-safe-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var info = StubMachman.makeInfo("Debian")
		info.disks = [DiskInfo(
			id: "storage:disk", type: .storage, name: "disk", path: nil, sizeBytes: nil)]
		stub.vms["Debian"] = info
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "safe")
		try await client.setSafety(vm: "Debian", disks: ["storage:disk": false], mounts: nil)
		#expect(try await client.vm(named: "Debian").disks.first?.safe == false)

		do {
			try await client.setSafety(vm: "Debian", disks: ["storage:bogus": true], mounts: nil)
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
		}
		await client.disconnect()
	}

	@Test @MainActor func diskImportAndPromoteRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-imp-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var info = StubMachman.makeInfo("Debian")
		info.disks = [DiskInfo(
			id: "url:file:///imgs/a.img", type: .image, name: nil, path: "/imgs/a.img",
			sizeBytes: 1024, safe: true, owned: false)]
		stub.vms["Debian"] = info
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "imp")
		let imported = try await client.importDisk(vm: "Debian", path: "/imgs/b.raw")
		#expect(imported.disks.contains { $0.name == "imported" && $0.owned == true })

		let promoted = try await client.promoteDisk(
			vm: "Debian", diskID: "url:file:///imgs/a.img")
		#expect(promoted.disks.allSatisfy { $0.owned == true })

		do {
			_ = try await client.promoteDisk(vm: "Debian", diskID: "storage:imported")
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)   // already owned
		}
		await client.disconnect()
	}

	@Test @MainActor func safeSaveRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-save-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var running = StubMachman.makeInfo("Debian", state: .running)
		running.safeRun = true
		stub.vms["Debian"] = running
		stub.vms["Other"] = StubMachman.makeInfo("Other")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "save")
		let saved = try await client.safeSave(vm: "Debian", to: "Debian kept")
		#expect(saved.name == "Debian kept")
		#expect(saved.safeRun == nil)
		#expect(try await client.listVMs().map(\.name) == ["Debian kept", "Other"])

		do {
			_ = try await client.safeSave(vm: "Other", to: "x")
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)   // not a safe run
		}
		await client.disconnect()
	}

	@Test @MainActor func retireRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-ret-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "ret")
		try await client.retire()
		#expect(stub.retired)
		await client.disconnect()
	}

	@Test @MainActor func engineErrorsKeepTheirCode() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-err-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		stub.fail("openWindow", with: VirtualMachineError.critical("boom"))
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "err")
		do {
			try await client.openWindow(vm: "Debian")
			Issue.record("expected a throw")
		} catch let error as MachmanError {
			// The boundary catch keeps a machmanCode and a clean message — no leaked
			// "critical(...)" Swift syntax.
			#expect(error.code == .internalError)
			#expect(error.message == "boom")
		}
		await client.disconnect()
	}

	@Test @MainActor func largeResponsesSurviveTheSocket() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-big-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian", state: .running)
		// 2 MiB of noise ≈ a real VM-window JPEG after base64 — far beyond the socket
		// buffer, so the server must handle partial writes.
		stub.previewPayload = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "big")
		let echoed = try await client.preview(vm: "Debian", maxWidth: nil)
		#expect(echoed == stub.previewPayload)
		// The connection must still work afterwards.
		#expect(try await client.vm(named: "Debian").name == "Debian")
		await client.disconnect()
	}

	@Test @MainActor func secondDaemonIsRefused() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-dup-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let second = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		#expect(throws: (any Error).self) {
			try second.start()
		}
	}

	// The 1.0.4 additions dispatch end to end: devices, enabled, overrides, resize,
	// operations, templates, nested-virt.
	@Test @MainActor func devicesAndOperationsRoundTrip() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-dev-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var seeded = StubMachman.makeInfo("Debian")
		seeded.disks = [DiskInfo(
			id: "storage:disk", type: .storage, name: "disk", path: nil, sizeBytes: 1024)]
		stub.vms["Debian"] = seeded
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "devices")

		// Templates ride vm.create's new optional params.
		_ = try await client.createVM(template: .mac)
		#expect(stub.lastCreateTemplate == .mac)

		// Device add → update → remove, VMInfo echoed each time.
		var info = try await client.addDevice(vm: "Debian", kind: .entropy)
		#expect(info.devices?.map(\.kind) == [.entropy])
		var device = DeviceInfo(kind: .entropy)
		device.enabled = false
		info = try await client.updateDevice(vm: "Debian", device: device)
		#expect(info.devices?.first?.enabled == false)
		info = try await client.removeDevice(vm: "Debian", kind: .entropy)
		#expect(info.devices?.isEmpty == true)

		// setEnabled: applies by id; unknown ids surface notFound with the daemon's message.
		try await client.setEnabled(
			vm: "Debian", disks: ["storage:disk": false], mounts: nil,
			console: nil, uart: nil)
		let flagged = try await client.vm(named: "Debian")
		#expect(flagged.disks.first?.isEnabled == false)
		do {
			try await client.setEnabled(
				vm: "Debian", disks: ["ghost": true], mounts: nil, console: nil, uart: nil)
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
		}

		// Kernel override + resize + hardware(nested) round-trip.
		_ = try await client.setKernelOverride(
			vm: "Debian", path: "/k", commandLine: "quiet", overrideEnabled: true)
		let resized = try await client.resizeDisk(
			vm: "Debian", diskID: "storage:disk", sizeBytes: 4096)
		#expect(resized.disks.first?.sizeBytes == 4096)
		try await client.setHardware(
			vm: "Debian", cpuCount: nil, memoryBytes: nil, nestedVirtualization: true)
		let nested = try await client.vm(named: "Debian")
		#expect(nested.nestedVirtualization == true)

		// Operations: list round-trips; cancel of an unknown id is notFound; rosetta refuses.
		stub.ops = [OperationInfo(
			id: "op-1", kind: OperationInfo.Kind.copyVM, vm: "Debian", label: "Copying…",
			startedAt: Date(timeIntervalSince1970: 1_700_000_000))]
		let ops = try await client.operations()
		#expect(ops.map(\.id) == ["op-1"])
		try await client.cancelOperation(id: "op-1")
		#expect(stub.ops.isEmpty)
		do {
			try await client.cancelOperation(id: "op-1")
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
		}
		do {
			try await client.installRosetta()
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
		}

		await client.disconnect()
	}
}
