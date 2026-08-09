//
//  RunDefaultsView.swift
//  Machman
//
//  The run-defaults strip: what a plain Run does (windowed or headless), whether runs are
//  safe, and whether the VM autostarts at login. Reads are stateless — every control renders
//  straight from the DTO and every write round-trips setStartPolicy → listChanged → fresh
//  VMInfo, so there is no @State to drift or reset per VM.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct RunDefaultsView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	// nil means the serving daemon predates start policies — render the defaults.
	private var policy: StartPolicy { vm.startPolicy ?? StartPolicy() }

	private func update(_ mutate: (inout StartPolicy) -> Void) {
		var changed = policy
		mutate(&changed)
		viewModel.setStartPolicy(vm.name, policy: changed)
	}

	// autostart && safe is refused on the wire; disable the OTHER toggle instead of letting
	// the user hit the error. The `&& !policy.x` escape keeps BOTH enabled if a hand-edited
	// config arrives with both true, so it can be un-stuck from the UI.
	private var safeLocked: Bool { policy.autostart && !policy.safe }
	private var autostartLocked: Bool { policy.safe && !policy.autostart }

	private var safeHelp: String {
		safeLocked
			? "Autostarted VMs cannot run safe — turn off autostart first"
			: "Discard all disk changes when the VM stops. Stored now; takes effect "
				+ "when safe mode ships."
	}

	private var autostartHelp: String {
		autostartLocked
			? "Safe-run VMs cannot autostart — turn off safe mode first"
			: "Start this VM at login, without the desktop app"
	}

	var body: some View {
		GroupBox {
			HStack {
				Picker("", selection: Binding(
					get: { policy.windowed },
					set: { windowed in update { $0.windowed = windowed } }
				)) {
					Image(systemName: MachmanSymbols.vmRunningWindowed).tag(true)
					Image(systemName: MachmanSymbols.vmRunningHeadless).tag(false)
				}
				.pickerStyle(.segmented)
				.fixedSize()
				.labelsHidden()
				.help(policy.windowed
					? "Plain Run opens a console window"
					: "Plain Run starts headless (no window)")
				Spacer()
				HStack {
					Image(systemName: MachmanSymbols.safe)
						.foregroundColor(.secondary)
					Toggle("Safe", isOn: Binding(
						get: { policy.safe },
						set: { safe in update { $0.safe = safe } }
					))
					.toggleStyle(.checkbox)
					.disabled(safeLocked)
				}
				.help(safeHelp)   // on the wrapper: tooltips on disabled controls don't fire
				HStack {
					Image(systemName: MachmanSymbols.autostart)
						.foregroundColor(.secondary)
					Toggle("Autostart", isOn: Binding(
						get: { policy.autostart },
						set: { autostart in update { $0.autostart = autostart } }
					))
					.toggleStyle(.checkbox)
					.disabled(autostartLocked)
				}
				.help(autostartHelp)
			}
			.padding(2)
		}
		.padding(2)
	}
}

#Preview {
}
