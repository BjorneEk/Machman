//
//  EngineDiskTests.swift
//  MachmanLabTests
//
//  L2 — disk edits whose failure must read as a sentence: a qcow2 import (E28) on the wire,
//  in the desktop's alert, its failed operation card (F9: the card's look is L1) and the
//  Activity list; and an owned ISO the engine can't delete from the VM's folder (D22).
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

@Suite("Engine — disks", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineDiskTests {
	static let qcowSentence =
		"Machman can’t use qcow2 images — convert to raw first (qemu-img convert -O raw)"

	/// A 1 MiB file that sniffs as qcow2 ("QFI\u{fb}").
	static func qcow(_ agent: LabAgent) throws -> String {
		var bytes = Data([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3])
		bytes.append(Data(count: (1 << 20) - bytes.count))
		let path = agent.scope.imagesDir + "/x.qcow2"
		try bytes.write(to: URL(fileURLWithPath: path))
		return path
	}

	@Test("W4-14: a qcow2 import fails with the convert sentence, never a MachmanError dump")
	func qcowImportSaysSentence() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(
				LabVMSpec(name: "qcow2-import", boot: .alpine()), start: false
			) { vm in
				let path = try Self.qcow(agent)
				do {
					_ = try await agent.api.importDisk(vm: vm.name, path: path)
					Issue.record("a qcow2 import was accepted")
				} catch let error as MachmanError {
					#expect(error.message == Self.qcowSentence)
				}
				let desktop = try await TFDesktop.make(agent: agent)
				desktop.viewModel.importDisk(vm.name, path: path)
				try await TFWait.until("the import alert", timeout: .seconds(15)) {
					desktop.viewModel.presentedError != nil
				}
				let alert = try #require(desktop.viewModel.presentedError)
				#expect(alert.message == Self.qcowSentence)
				let ops = try await agent.api.operations().filter {
					$0.vm == vm.name && $0.state == OperationInfo.State.failed
				}
				#expect(ops.contains { $0.message == Self.qcowSentence })
				try await TFWait.until("the failed import in Activity", timeout: .seconds(10)) {
					desktop.viewModel.activity.entries.contains { $0.detail == Self.qcowSentence }
				}
				let texts = [alert.message, alert.title]
					+ ops.compactMap(\.message)
					+ desktop.viewModel.activity.entries.compactMap(\.detail)
				#expect(!texts.contains { $0.contains("MachmanError(") })
				await desktop.close()
			}
		}
	}

	@Test("W4-29: the failed import's operation keeps the sentence and no progress")
	func failedImportOperation() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(
				LabVMSpec(name: "failed-import", boot: .alpine()), start: false
			) { vm in
				let desktop = try await TFDesktop.make(agent: agent)
				let path = try Self.qcow(agent)
				_ = try? await agent.api.importDisk(vm: vm.name, path: path)
				let op = try #require(try await agent.api.operations().first {
					$0.vm == vm.name && $0.state == OperationInfo.State.failed
				})
				#expect(op.message == Self.qcowSentence)
				#expect(op.fraction == nil || op.fraction == 0)
				try await TFWait.until("the failed card in the store", timeout: .seconds(10)) {
					desktop.operations.operations.contains {
						$0.id == op.id && $0.state == OperationInfo.State.failed
					}
				}
				let card = try #require(desktop.operations.operations.first { $0.id == op.id })
				#expect(card.message == Self.qcowSentence)
				#expect(card.fraction == nil || card.fraction == 0)
				await desktop.close()
			}
		}
	}

	@Test("R3W2-46: an owned ISO that can't be deleted leaves the list with one warning")
	func undeletableOwnedISO() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(
				LabVMSpec(name: "owned-iso", boot: .alpine()), start: false
			) { vm in
				let isos = TFVM.dir(agent, vm.name) + "/isos"
				try FileManager.default.createDirectory(
					atPath: isos, withIntermediateDirectories: true)
				let iso = isos + "/x.iso"
				FileManager.default.createFile(atPath: iso, contents: Data(count: 2 << 20))
				try await agent.api.addDisk(vm: vm.name, .iso(path: iso))
				let disk = try #require(try await vm.info().disks.first { $0.path == iso })
				#expect(disk.owned == true)
				chmod(isos, 0o555)
				defer { chmod(isos, 0o755) }
				let events = await TFEvents(api: agent.api)
				defer { events.stop() }
				try await agent.api.removeDisk(vm: vm.name, diskID: disk.id)
				#expect(try await vm.info().disks.contains { $0.id == disk.id } == false)
				let sentence =
					"“x.iso” couldn’t be deleted from the VM’s folder — remove it by hand."
				try await events.waitFor("the orphan warning", timeout: .seconds(10)) {
					$0 == .log(vm: "owned-iso", level: .warning, message: sentence)
				}
				try await Task.sleep(for: .seconds(1))
				let warned = events.logs(vm: "owned-iso", level: .warning).filter { $0 == sentence }
				#expect(warned.count == 1)
				#expect(FileManager.default.fileExists(atPath: iso))
			}
		}
	}
}
