//
//  PasteboardWatchTests.swift
//  MachmanDesktopCoreTests
//
//  Paste enablement follows the pasteboard (H25): Paste items read the pasteboard as their
//  menus were built and nothing observed it, so a copy in Finder left them disabled. The
//  watch re-reads on its triggers when the change count moved, and only then. Each test
//  posts on its own NotificationCenter with a fake pasteboard.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct PasteboardWatchTests {
	// A pasteboard the test controls: its change count, its file URLs, and how often it
	// was read.
	@MainActor
	private final class FakePasteboard {
		var count = 0
		var files: [URL] = []
		var entities: [EntityClipboard] = []
		var reads = 0
	}

	private let trigger = Notification.Name("PasteboardWatchTests.trigger")

	private func watch(
		_ board: FakePasteboard, center: NotificationCenter
	) -> PasteboardWatch {
		PasteboardWatch(
			center: center, triggers: [trigger], changeCount: { board.count },
			read: {
				board.reads += 1
				return PasteboardSnapshot(
					entities: board.entities, fileURLs: board.files,
					isDirectory: { $0.hasDirectoryPath })
			})
	}

	@Test func anActivationAfterACopyEnablesPaste() async {
		let board = FakePasteboard()
		let center = NotificationCenter()
		let watch = watch(board, center: center)
		#expect(!watch.snapshot.canPasteAnything)
		board.count += 1
		board.files = [URL(fileURLWithPath: "/Users/demo/Downloads/disk.raw")]
		center.post(name: trigger, object: nil)
		#expect(await eventually { watch.snapshot.canPasteAnything })
		#expect(watch.snapshot.canPaste(into: .disks))
	}

	@Test func anUnchangedPasteboardIsNotReread() async {
		let board = FakePasteboard()
		let center = NotificationCenter()
		let watch = watch(board, center: center)
		for _ in 0..<5 { center.post(name: trigger, object: nil) }
		await Task.yield()
		#expect(board.reads == 1)   // the init read
		watch.refresh()
		#expect(board.reads == 1)
	}

	// The drop rules: folders mount, files attach as disks (not qcow2) or kernel files.
	@Test func sectionsTakeOnlyWhatFits() {
		let folder = PasteboardSnapshot(
			entities: [], fileURLs: [URL(fileURLWithPath: "/Users/demo/src/", isDirectory: true)],
			isDirectory: { $0.hasDirectoryPath })
		#expect(folder.canPaste(into: .mounts))
		#expect(!folder.canPaste(into: .disks))
		#expect(!folder.canPaste(into: .kernel(.kernel)))
		let qcow = PasteboardSnapshot(
			entities: [], fileURLs: [URL(fileURLWithPath: "/Users/demo/disk.qcow2")],
			isDirectory: { $0.hasDirectoryPath })
		#expect(!qcow.canPaste(into: .disks))
		#expect(!qcow.canPaste(into: .mounts))
		#expect(qcow.canPaste(into: .kernel(.initramfs)))
		#expect(!PasteboardSnapshot.empty.canPaste(into: .disks))
	}

	@Test func entitiesDecideBeforeFiles() {
		let snapshot = PasteboardSnapshot(
			entities: [EntityClipboard(kind: .disk, path: "/Users/demo/disk.raw")],
			fileURLs: [URL(fileURLWithPath: "/Users/demo/src/", isDirectory: true)],
			isDirectory: { $0.hasDirectoryPath })
		#expect(snapshot.canPasteAnything)
		#expect(snapshot.canPaste(into: .disks))
		#expect(!snapshot.canPaste(into: .mounts))
	}

	// Machman's own copies refresh at once (EntityClipboard.write calls refresh).
	@Test func aWriteRefreshesAtOnce() {
		let board = FakePasteboard()
		let watch = watch(board, center: NotificationCenter())
		board.count += 1
		board.entities = [EntityClipboard(kind: .mount, path: "/Users/demo/src", tag: "src")]
		watch.refresh()
		#expect(watch.snapshot.canPaste(into: .mounts))
		#expect(board.reads == 2)
	}

	// Each of the four sections judged the files on its own, so every copied file was
	// statted four times on the main thread at every read.
	@Test("P11: a pasteboard read stats each file once")
	func aReadStatsEachFileOnce() {
		let files = [
			URL(fileURLWithPath: "/Users/demo/src/", isDirectory: true),
			URL(fileURLWithPath: "/Users/demo/disk.raw"),
			URL(fileURLWithPath: "/Users/demo/vmlinuz"),
		]
		var stats = 0
		let snapshot = PasteboardSnapshot(entities: [], fileURLs: files, isDirectory: {
			stats += 1
			return $0.hasDirectoryPath
		})
		#expect(stats == files.count)
		#expect(snapshot.canPaste(into: .mounts) && snapshot.canPaste(into: .disks))
	}
}
