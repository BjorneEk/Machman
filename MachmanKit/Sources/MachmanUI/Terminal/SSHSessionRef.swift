//
//  SSHSessionRef.swift
//  MachmanUI
//
//  Identity of one ephemeral SSH session tab. Unlike SerialPortRef there is no underlying
//  device: every + press mints a fresh UUID, the session lives exactly as long as its tab,
//  and the canvas store strips these tabs from persistence — an SSH session can never be
//  restored, only opened anew.
//

import Foundation

public struct SSHSessionRef: Hashable, Sendable, Codable, Identifiable {
	public let id: UUID
	public let title: String   // "user@address" at open time — fixed for the tab's life

	public init(id: UUID = UUID(), title: String) {
		self.id = id
		self.title = title
	}
}
