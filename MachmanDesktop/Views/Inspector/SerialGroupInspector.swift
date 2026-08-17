//
//  SerialGroupInspector.swift
//  MachmanDesktop
//
//  The Serial group's inspector (1.0.7): one row per interface with the login state the
//  guest-setup script reported — active (and whether systemd did it on its own),
//  configured for the next boot, none, or missing — plus the kernel-console marker and
//  the host gate on uarts. Per-port settings stay in each port's own inspector.
//

import SwiftUI
import MachmanUI
import MachmanAPI

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
							Text("/dev/" + port.guestDevice)
								.font(.system(.callout, design: .monospaced))
							if reportedInfo(for: port)?.kernelConsole == true {
								Text("kernel")
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

	// The report keys interfaces by the name the GUEST saw at run time; ports renumber
	// compactly, so match on guestDevice.
	private func reportedInfo(for port: SerialPortInfo) -> GuestConsoleInfo? {
		reported.first { $0.device == port.guestDevice }
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
