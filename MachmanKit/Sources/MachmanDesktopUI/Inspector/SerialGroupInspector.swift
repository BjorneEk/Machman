//
//  SerialGroupInspector.swift
//  MachmanDesktopUI
//
//  The Serial group's inspector (1.0.7): one row per interface with the login state the
//  guest-setup script reported — active (and whether systemd did it on its own),
//  configured for the next boot, none, or missing — plus the kernel-console marker and
//  the host gate on uarts. Per-port settings stay in each port's own inspector.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct SerialGroupInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	private var ports: [SerialPortInfo] {
		(vm.consolePorts ?? []) + (vm.uartPorts ?? [])
	}
	private var reported: [GuestConsoleInfo] { vm.setup?.consoles ?? [] }

	var body: some View {
		Form {
			Section("Interfaces") {
				if ports.isEmpty {
					Text("No serial interfaces — add a console with (+).")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				ForEach(ports) { port in
					LabeledContent {
						Text(summary(for: port))
							.foregroundStyle(port.unavailable == nil ? .secondary : .tertiary)
					} label: {
						HStack(spacing: 5) {
							Text(port.deviceLabel(mode: vm.boot.mode))
								.font(.system(.callout, design: .monospaced))
							if reportedInfo(for: port)?.kernelConsole == true {
								Text("kernel")
									.font(.caption2)
									.foregroundStyle(.tertiary)
							} else if reportedInfo(for: port)?.kernelConsolePending == true {
								Text("kernel (next boot)")
									.font(.caption2)
									.foregroundStyle(.tertiary)
							}
						}
					}
				}
			}
			if !reported.isEmpty {
				Section {
					Text("Login states come from the guest-setup script's last run.")
						.font(.caption)
						.foregroundStyle(.tertiary)
				}
			}
		}
	}

	// CONSOLE_N report lines are emitted in the guest's enabled-compacted order — the
	// same numbering guestIndex carries — so the join is positional. (Matching on the
	// baked guestDevice broke on EFI: the daemon guessed hvc0 while a FreeBSD guest
	// reported ttyV0.0.) Name-equality stays as the older-daemon fallback.
	private func reportedInfo(for port: SerialPortInfo) -> GuestConsoleInfo? {
		// The guest only ever saw enabled ports; a disabled port's config-position
		// guestIndex could collide with an enabled port's compacted one.
		guard port.kind == .console, port.isEnabled else { return nil }
		let position = port.guestIndex ?? port.index
		if reported.indices.contains(position) { return reported[position] }
		return reported.first { $0.device == port.guestDevice }
	}

	private func summary(for port: SerialPortInfo) -> String {
		if let gate = port.unavailable {
			return gate.sinceOSVersion.map { "unavailable ≥ \($0)" } ?? "unavailable"
		}
		if !port.isEnabled {
			return "disabled"
		}
		guard port.kind == .console else {
			return "uart"
		}
		let reported = reportedInfo(for: port)
		let external = reported?.external == true ? " (outside Machman)" : ""
		switch reported?.login {
		case "active-auto": return "login active (automatic)"
		case "active": return "login active" + external
		case "configured": return "login configured (next boot)" + external
		case "missing": return "not present in the guest"
		case "none": return "no login"
		case .some(let other): return other   // a newer script's state renders verbatim
		case nil: return "no report yet"
		}
	}
}
