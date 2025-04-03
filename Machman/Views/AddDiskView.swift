//
//  AddDiskView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-01.
//

import SwiftUI
import Foundation
extension View {
	func placeholder<Content: View>(
		when shouldShow: Bool,
		alignment: Alignment = .leading,
		@ViewBuilder placeholder: () -> Content
	) -> some View {
		ZStack(alignment: alignment) {
			if shouldShow {
				placeholder().padding(.horizontal, 4)
			}
			self
		}
	}
}

struct AddDiskView: View {
	@State private var name: String = ""
	@State private var iso: String = ""
	@State private var disk: String = ""
	@State private var size: String = ""
	@State private var vmDiskSize: UInt64 = 0
	@State private var vmDiskSizeStringGB: String = ""
	var addIso: (URL) -> Void = { _ in }
	var addFrom: (URL) -> Void = { _ in }
	var addNew: (_ name: String, _ size: UInt64) -> Void = { _,_  in }

	static func getAvailableVMDiskSpace() -> Int? {
		let homeURL = URL(fileURLWithPath: machmanVMDir)

		do {
			let values = try homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
			if let available = values.volumeAvailableCapacityForImportantUsage {
				return VMConfig.toGB(size: UInt64(available)) // in bytes
			}
			return nil
		} catch {
			return nil
		}
	}
	var body: some View {
			TabView {
				VStack {
					HStack {
						Image(systemName: "internaldrive.fill")
							.foregroundColor(.secondary)
						TextField("Name", text: $name)
							.textFieldStyle(.roundedBorder)
					}
					Divider()
					HStack {
						Image(systemName: "gauge.with.needle")
							.foregroundColor(.secondary)
						TextField("", text: $size)
							.textFieldStyle(.roundedBorder)
							.onReceive(size.publisher.collect()) { chars in
								DispatchQueue.main.async {
									size = String(size.prefix(4).filter { "0123456789".contains($0) })
									if (Int(size) ?? 0 > AddDiskView.getAvailableVMDiskSpace() ?? Int.max) {
										size = (AddDiskView.getAvailableVMDiskSpace() ?? Int.max).formatted()
									}
								}
							}
							.placeholder(when: size.isEmpty) {
								Text("Size GB (max \(Self.getAvailableVMDiskSpace() ?? 0) GB)")
									.padding(.horizontal)
											.foregroundColor(.secondary)
						}
					}
					//.pickerStyle(.inline)
					Divider()
					HStack {
						Button(action: {
							addNew(name, VMConfig.fromGB(size: Int(size) ?? 0))
						}) {
							Image(systemName: "plus")
								.foregroundColor(.secondary)
						}.padding(.trailing)
						Text("Add new disk")
						Spacer()
					}
				}.padding()
				.tabItem {
					Label("new", systemImage: "externaldrive.fill")
				}

				VStack {
					HStack {
						Button(action: {
							let panel = NSOpenPanel()
							panel.canChooseFiles = true
							panel.canChooseDirectories = true
							panel.allowsMultipleSelection = false
							panel.allowedContentTypes = [.diskImage]
							panel.begin { response in
								if response == .OK, let selectedURL = panel.url {
									print(selectedURL.path)
									iso = selectedURL.path
								}
							}
						}) {
							Image(systemName: "folder.fill.badge.plus")
								.font(.title2)
						}
						TextField("iso file", text: $iso)
							.textFieldStyle(.roundedBorder)
					}
					Divider()
					HStack {
						Button(action: {
							addIso(URL(fileURLWithPath: iso))
						}) {
							Image(systemName: "plus")
								.foregroundColor(.secondary)
						}.padding(.trailing)
						Text("Add new iso boot disk")
						Spacer()
					}
				}.padding()
					.tabItem {
						Label("iso boot drive", systemImage: "externaldrive.fill.badge.icloud")
					}

				VStack {
					HStack {
						Button(action: {
							let panel = NSOpenPanel()
							panel.canChooseFiles = true
							panel.canChooseDirectories = true
							panel.allowsMultipleSelection = false
							panel.allowedContentTypes = [.diskImage]
							panel.begin { response in
								if response == .OK, let selectedURL = panel.url {
									print(selectedURL.path)
									disk = selectedURL.path
								}
							}
						}) {
							Image(systemName: "folder.fill.badge.plus")
								.font(.title2)
						}
						TextField("Path", text: $disk)
							.textFieldStyle(.roundedBorder)
					}
					Divider()
					HStack {
						Button(action: {
							addFrom(URL(fileURLWithPath: disk))
						}) {
							Image(systemName: "plus")
								.foregroundColor(.secondary)
						}.padding(.trailing)
						Text("Add disk")
						Spacer()
					}
				}.padding()
					.tabItem {
						Label("browse", systemImage: "externaldrive.connected.to.line.below.fill")
					}
			}
			.tabViewStyle(.automatic) // or .page, .segmented if you want specific look
	}
}

#Preview {
    AddDiskView()
}
