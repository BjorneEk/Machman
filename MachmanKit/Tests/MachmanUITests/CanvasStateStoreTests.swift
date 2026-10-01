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

	@Test func renameMigratesAndRemoveForgets() throws {
		let url = tempURL()
		defer { try? FileManager.default.removeItem(at: url) }
		var canvas = CanvasState()
		canvas.open(.terminal(tty0))

		let store = CanvasStateStore(fileURL: url)
		store.setCanvas(canvas, for: "old")
		store.renameVM(from: "old", to: "new")
		#expect(store.canvases["old"] == nil)
		#expect(store.canvas(for: "new") == canvas)
		store.removeVM("new")
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
}
