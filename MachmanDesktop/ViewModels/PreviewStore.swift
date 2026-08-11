//
//  PreviewStore.swift
//  MachmanDesktop
//
//  The live VM preview thumbnails, isolated in their own ObservableObject. The preview loop
//  refreshes an image every few seconds; keeping it off VMListViewModel means only the small
//  PreviewView re-renders on each frame — not the whole VM pane (tab strip, terminal NSView,
//  toolbar), which observes VMListViewModel and would otherwise churn (dropping tab clicks).
//

import AppKit

@MainActor
final class PreviewStore: ObservableObject {
	@Published var images: [String: NSImage] = [:]
}
