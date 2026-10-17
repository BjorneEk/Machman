import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanUI

// Persistence of per-VM canvas layouts: round-trip through a fresh store, rename/remove
// migration, and reconcile writing back the pruned layout.
@MainActor
struct CanvasStateStoreTests {

	private let hvc0 = SerialPortRef(kind: .console, index: 0)
	private let tty0 = SerialPortRef(kind: .uart, index: 0)

	private func tempURL() -> URL {
		TestEnvironment.scratchURL
			.appendingPathComponent("canvas-store-\(UUID().uuidString).json")
	}

	@Test func roundTripThroughAFreshStore() throws {
		let url = tempURL()
		defer { try? FileManager.default.removeItem(at: url) }
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.split(.terminal(hvc0))
		canvas.setFraction(0.3, at: 0)

		let store = CanvasStateStore(fileURL: url)
		// Unsaved VM: no entry, and the fallback is a fresh single-pane layout. (No equality
		// against CanvasState() — every init mints new pane ids.)
		#expect(store.canvases["debian"] == nil)
		#expect(store.canvas(for: "debian").allOpenTabs.isEmpty)
		store.setCanvas(canvas, for: "debian")
		store.flush()

		let reloaded = CanvasStateStore(fileURL: url)
		#expect(reloaded.canvas(for: "debian") == canvas)
	}

	// SSH tabs are sessions, not layout: a saved canvas comes back WITHOUT them.
	@Test func sshTabsAreNeverPersisted() throws {
		let url = tempURL()
		defer { try? FileManager.default.removeItem(at: url) }
		let ref = SSHSessionRef(title: "admin@192.168.64.9")
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.open(.ssh(ref))

		let store = CanvasStateStore(fileURL: url)
		store.setCanvas(canvas, for: "debian")
		store.flush()

		let reloaded = CanvasStateStore(fileURL: url)
		let tabs = reloaded.canvas(for: "debian").allOpenTabs
		#expect(!tabs.contains(.ssh(ref)))
		#expect(tabs.contains(.terminal(hvc0)))
		#expect(tabs.contains(.config))
		let raw = try String(contentsOf: url, encoding: .utf8)
		#expect(!raw.contains(#""kind" : "ssh""#) && !raw.contains(#""kind":"ssh""#))
	}

	// Absence from one list forgets nothing; this desktop's delete does (T33).
	@Test("T33: a rename moves a layout, a list without it keeps it, and a delete forgets it")
	func renameMigratesAndDeleteForgets() throws {
		let url = tempURL()
		defer { try? FileManager.default.removeItem(at: url) }
		var canvas = CanvasState()
		canvas.open(.terminal(tty0))

		let store = CanvasStateStore(fileURL: url)
		store.setCanvas(canvas, for: "old")
		store.renameVM(from: "old", to: "new")
		#expect(store.canvases["old"] == nil)
		#expect(store.canvas(for: "new") == canvas)
		store.forgetVMs(except: ["other"])
		#expect(store.canvas(for: "new") == canvas)
		store.vmDeleted("new")
		store.flush()

		let reloaded = CanvasStateStore(fileURL: url)
		#expect(reloaded.canvases.isEmpty)
	}

	@Test func reconcilePrunesAndPersists() throws {
		let url = tempURL()
		defer { try? FileManager.default.removeItem(at: url) }
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.open(.terminal(tty0))

		let store = CanvasStateStore(fileURL: url)
		store.setCanvas(canvas, for: "vm")
		#expect(store.reconcile(vm: "missing", existing: []) == [])
		let removed = store.reconcile(vm: "vm", existing: [hvc0])
		#expect(removed == [tty0])
		store.flush()

		let reloaded = CanvasStateStore(fileURL: url)
		let tabs = reloaded.canvas(for: "vm").allOpenTabs
		#expect(tabs == [.config, .terminal(hvc0)])
	}

	// MARK: - Unreadable values and files (P19)

	@Test func anUnreadableLayoutFileIsSetAside() throws {
		let url = tempURL()
		try Data("{ truncated".utf8).write(to: url)
		let store = CanvasStateStore(fileURL: url)
		#expect(store.canvases.isEmpty)
		var canvas = CanvasState()
		canvas.open(.config)
		store.setCanvas(canvas, for: "debian")
		store.flush()
		let backup = URL(fileURLWithPath: url.path + ".bak")
		#expect(try String(contentsOf: backup, encoding: .utf8) == "{ truncated")
		#expect(CanvasStateStore(fileURL: url).canvas(for: "debian") == canvas)
		#expect(store.takeSetAsideNotice()?.what == "tab layouts")
	}

	@Test func oneBrokenLayoutCostsOnlyThatVM() throws {
		let url = tempURL()
		var good = CanvasState()
		good.open(.config)
		good.open(.terminal(hvc0))
		let encoded = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
		try Data(#"{"canvases": {"good": \#(encoded), "broken": 42}}"#.utf8).write(to: url)
		let store = CanvasStateStore(fileURL: url)
		#expect(store.canvas(for: "good") == good)
		#expect(store.canvases["broken"] == nil)
	}

	// A tab kind another build wrote is dropped on reload, not turned into a second config
	// tab (T12).
	@Test func aLayoutWithAnUnknownTabReloadsWithoutIt() throws {
		let url = tempURL()
		try Data(#"""
			{"canvases": {"debian": {"panes": [{"id": "0A000000-0000-4000-8000-00000000000A",
			  "tabs": [{"kind": "config"}, {"kind": "history"}]}]}}}
			"""#.utf8).write(to: url)
		let store = CanvasStateStore(fileURL: url)
		#expect(store.canvas(for: "debian").allOpenTabs == [.config])
	}

	// MARK: - Coalesced writes (P9's per-frame write half)

	// A divider drag calls setCanvas every frame; the file is written after the drag, not
	// per frame, and flush() lands the final layout.
	@Test func aDividerDragWritesOnceNotPerFrame() async throws {
		let url = tempURL()
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.split(.terminal(hvc0))
		let store = CanvasStateStore(fileURL: url, saveDelay: .seconds(5))
		for frame in 0..<120 {
			canvas.setFraction(0.2 + Double(frame) * 0.005, at: 0)
			store.setCanvas(canvas, for: "debian")
		}
		try await Task.sleep(for: .milliseconds(100))
		#expect(!FileManager.default.fileExists(atPath: url.path))
		store.flush()
		#expect(CanvasStateStore(fileURL: url).canvas(for: "debian") == canvas)
	}

	@Test func aQuietPeriodWritesOnItsOwn() async throws {
		let url = tempURL()
		var canvas = CanvasState()
		canvas.open(.config)
		let store = CanvasStateStore(fileURL: url, saveDelay: .milliseconds(50))
		store.setCanvas(canvas, for: "debian")
		#expect(await eventually { FileManager.default.fileExists(atPath: url.path) })
	}

	// A click on the active tab, or any tap on a strip, hands back the layout unchanged; it
	// republished the whole store (window, menus, torn windows) and queued a write anyway.
	@Test("P36: an unchanged layout neither republishes nor writes")
	func anUnchangedLayoutIsANoOp() throws {
		let url = tempURL()
		defer { try? FileManager.default.removeItem(at: url) }
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		let store = CanvasStateStore(fileURL: url, saveDelay: .seconds(5))
		store.setCanvas(canvas, for: "debian")
		store.flush()
		try FileManager.default.removeItem(at: url)
		var publishes = 0
		let watch = store.objectWillChange.sink { publishes += 1 }
		store.setCanvas(canvas, for: "debian")
		store.setCanvas(store.canvas(for: "debian"), for: "debian")
		watch.cancel()
		store.flush()
		#expect(publishes == 0)
		#expect(!FileManager.default.fileExists(atPath: url.path))
	}
}
