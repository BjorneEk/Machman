//
//  GuestSetupInspector.swift
//  MachmanDesktopUI
//
//  The unified installer's home (1.0.7): status from the guest's report (the script it ran
//  and the one the VM serves, GuestSetupScriptRows (S67); the detected OS, the last run, the
//  errors and notes popdowns), the per-feature list, and the setup commands per boot mode —
//  auto-collapsed behind a checkmark once installed, with an Allow-reinstall toggle to bring
//  them back. Inspector text rule: nothing longer
//  than one sentence — details live in the Setup Guide sheet, never here. The report's and
//  the commands' disclosures change nothing, so they stay live under a settings lock (H62).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct GuestSetupInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@State private var showGuide = false
	@State private var allowReinstall = false
	@State private var resetConfirm = false

	private var device: DeviceInfo? {
		(vm.devices ?? []).first { $0.kind == .guestSetup }
	}
	private var setup: GuestSetupInfo? { vm.setup }
	private var installed: Bool { setup?.installed == true }
	// A failed last run keeps the installer served (the daemon's serve rule) until a run
	// gets through: its commands stay out, whatever the reinstall toggle says.
	private var lastRunFailed: Bool { setup?.lastRunStatus == GuestRunStatus.failed }

	var body: some View {
		Form {
			if let gate = device?.unavailable {
				UnavailableGateSection(gate)
			}
			statusSection
			featuresSection
			setupSection
			Section {
				Button("Reset Setup State…", role: .destructive) { resetConfirm = true }
					.confirmationDialog("Reset guest setup state?", isPresented: $resetConfirm) {
						Button("Reset", role: .destructive) { viewModel.resetSetup(vm.name) }
						Button("Cancel", role: .cancel) {}
					} message: {
						Text("Forgets the guest’s report — the guest keeps what the "
							+ "script installed, and SSH state has its own reset.")
					}
			}
			if let device {
				DeviceImplementationSection(vm: vm, device: device)
				DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .guestSetup)
			}
		}
		.sheet(isPresented: $showGuide) {
			GuestSetupHelpSheet(vm: vm).liveWhileSettingsLocked()
		}
	}

	// MARK: - Status

	private var statusSection: some View {
		Section("Status") {
			GuestSetupInstalledRow(setup: setup)
			GuestSetupServesRow(viewModel: viewModel, vm: vm)
			// While setup is (re)installable the row says what a run will find — the
			// share already automounted (and how) or merely available. Installed and
			// collapsed, the ephemeral-payload lifecycle line returns.
			if installed && !allowReinstall && !lastRunFailed {
				// Not serving: the reserved dirs ride the share EMPTY (content only
				// while installing — the toggle below brings it back).
				LabeledContent("Payload") {
					Text("Not served — the share stays clean")
						.foregroundStyle(.secondary)
				}
			} else {
				LabeledContent("Share") {
					Text(shareTransport).foregroundStyle(.secondary)
				}
			}
			if let setup, installed {
				// The OS by name, never its raw id (W6): one Machman doesn't know keeps only
				// its version and init system.
				let guest = [
					[GuestOSName.known(setup.guestOS), setup.guestOSVersion]
						.compactMap { $0 }.joined(separator: " "),
					setup.guestInit ?? "",
				].filter { !$0.isEmpty }.joined(separator: ", ")
				if setup.guestOS != nil, !guest.isEmpty {
					LabeledContent("Guest") {
						Text(guest)
							.font(.system(.callout, design: .monospaced))
					}
				}
				if let at = setup.lastReportAt {
					LabeledContent("Last run") {
						Text(at.formatted(date: .abbreviated, time: .shortened))
					}
				}
				if let transport = setup.lastTransport {
					LabeledContent("Transport", value: transport)
				}
				errorsPopdown
				notesPopdown
			} else {
				Text("No report yet — run the installer in the guest.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	// What carries the share into the guest: "virtiofs auto" / "sshfs auto" when the
	// guest automounts it, else "Available" — served, mount by hand.
	private var shareTransport: String {
		switch shareAutomountKind {
		case MountKind.virtiofs?: return "virtiofs auto"
		case MountKind.sshfs?: return "sshfs auto"
		default: return "Available"
		}
	}

	// The transport the guest automounts the share over, nil when it doesn't — the one
	// test both the Share row and the setup captions read, never the row's display text.
	private var shareAutomountKind: String? {
		let automounts = setup?.automounts ?? []
		if automounts.contains(where: { $0.kind == MountKind.virtiofs }) {
			return MountKind.virtiofs
		}
		if automounts.contains(where: { $0.kind == MountKind.sshfs && $0.target == "@share" }) {
			return MountKind.sshfs
		}
		return nil
	}

	@ViewBuilder
	private var errorsPopdown: some View {
		if let errors = setup?.errors, !errors.isEmpty {
			DisclosureGroup("Errors (\(errors.count))") {
				reportLines(errors)
			}
			.liveWhileSettingsLocked()
		}
	}

	// What the run noted without failing (a repair it made, a boot refresh that won't run).
	@ViewBuilder
	private var notesPopdown: some View {
		if let notes = setup?.notes, !notes.isEmpty {
			DisclosureGroup("Notes (\(notes.count))") {
				reportLines(notes)
			}
			.liveWhileSettingsLocked()
		}
	}

	// The report's "step: message" lines, scrolling past a handful.
	private func reportLines(_ lines: [GuestSetupError]) -> some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
					Text(line.step.isEmpty ? line.message : "\(line.step): \(line.message)")
						.font(.system(.caption, design: .monospaced))
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.frame(maxHeight: 120)
	}

	// MARK: - Features

	private var availableFeatures: [GuestFeatureInfo] {
		(setup?.features ?? []).filter(\.available)
	}
	private var unavailableFeatures: [GuestFeatureInfo] {
		(setup?.features ?? []).filter { !$0.available }
	}

	@ViewBuilder
	private var featuresSection: some View {
		if !(setup?.features ?? []).isEmpty {
			Section("Features") {
				ForEach(availableFeatures, id: \.id) { feature in
					LabeledContent(Self.featureTitle(feature.id)) {
						Text(featureSummary(feature))
							.foregroundStyle(feature.configured ? .primary : .secondary)
					}
				}
				if !unavailableFeatures.isEmpty {
					DisclosureGroup("Unavailable (\(unavailableFeatures.count))") {
						ForEach(unavailableFeatures, id: \.id) { feature in
							VStack(alignment: .leading, spacing: 2) {
								Text(Self.featureTitle(feature.id))
								Text(feature.reason ?? "Not available on this guest")
									.font(.caption)
									.foregroundStyle(.secondary)
									.fixedSize(horizontal: false, vertical: true)
							}
						}
					}
					.liveWhileSettingsLocked()
				}
			}
		}
	}

	private func featureSummary(_ feature: GuestFeatureInfo) -> String {
		guard feature.configured else { return "Not configured" }
		return feature.detail ?? "Configured"
	}

	static func featureTitle(_ id: String) -> String {
		switch id {
		case GuestFeature.console: return "Console logins"
		case GuestFeature.kernelConsole: return "Kernel console"
		case GuestFeature.ssh: return "SSH"
		case GuestFeature.reverseSSH: return "Guest → Mac SSH"
		case GuestFeature.sshfs: return "sshfs"
		case GuestFeature.virtiofsAutomount: return "Share automount"
		case GuestFeature.sshfsAutomount: return "sshfs automounts"
		default: return id   // a newer script's feature renders verbatim
		}
	}

	// MARK: - Setup commands

	@ViewBuilder
	private var setupSection: some View {
		Section("Setup") {
			if installed && !allowReinstall && !lastRunFailed {
				Label("Installed — the script ran in this guest.",
					systemImage: MachmanSymbols.activeEntry)
					.foregroundStyle(MachmanColors.stateRunning)
				Toggle("Allow reinstall or update", isOn: $allowReinstall)
			} else {
				if installed {
					Toggle("Allow reinstall or update", isOn: $allowReinstall)
				}
				setupCommands
				GuideButton(isPresented: $showGuide)
			}
			if installed, vm.state.isRunning {
				Text(serveCaption)
					.font(.caption)
					.foregroundStyle(.tertiary)
			}
		}
		// The toggle mirrors the PERSISTED reinstallRequested (vm.setup.serve): synced
		// from the DTO so it survives inspector rebuilds and app restarts, pushed only
		// on real changes so the sync can never echo.
		.onAppear { allowReinstall = setup?.reinstallRequested == true }
		.onChange(of: setup?.reinstallRequested) { _, served in
			allowReinstall = served == true
		}
		.onChange(of: allowReinstall) { _, serve in
			if serve != (setup?.reinstallRequested == true) {
				viewModel.setSetupServed(vm.name, serve: serve)
			}
		}
	}

	// The serve boundary, stated where it is decided: on = filled live, off = content leaves
	// with the run (never yanked from under the guest). A failed last run serves whatever
	// the toggle says, so the caption names the failure, not the toggle, as the reason.
	private var serveCaption: String {
		if allowReinstall { return "Serving — the installer is in the share." }
		if lastRunFailed { return "Serving because the last run failed." }
		return "Not serving — clears at shutdown if present."
	}

	// The share automounts (either transport): mounting instructions would contradict
	// the Share row above, so the run command stands alone.
	private var shareAutomounted: Bool { shareAutomountKind != nil }

	@ViewBuilder
	private var setupCommands: some View {
		switch vm.boot.mode {
		case .macOS:
			Text("Run in the guest’s Terminal (the share automounts, macOS 13+):")
				.font(.caption)
				.foregroundStyle(.secondary)
			CommandBlock(GuestSetupCommands.run(.macOS, shareMounted: true))
		case .linuxKernel:
			Text(shareAutomounted
				? "Run in the guest (the share automounts):"
				: "Run in the guest (mounts the share, then the installer):")
				.font(.caption)
				.foregroundStyle(.secondary)
			CommandBlock(GuestSetupCommands.run(.linux, shareMounted: shareAutomounted))
		case .efi, .unknown:
			DisclosureGroup("Linux") {
				VStack(alignment: .leading, spacing: 6) {
					Text(shareAutomounted
						? "The share automounts — run the installer:"
						: "Mounts the share, then runs the installer:")
						.font(.caption)
						.foregroundStyle(.secondary)
					CommandBlock(GuestSetupCommands.run(.linux, shareMounted: shareAutomounted))
				}
				.padding(.vertical, 2)
			}
			.liveWhileSettingsLocked()
			DisclosureGroup("FreeBSD / OpenBSD") {
				VStack(alignment: .leading, spacing: 6) {
					Text(shareAutomounted
						? "The share automounts over SSH — run the installer:"
						: "No virtiofs driver, so mount the share over sshfs first (see the "
							+ "Setup Guide), then run:")
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					CommandBlock(GuestSetupCommands.run(.bsd, shareMounted: true))
				}
				.padding(.vertical, 2)
			}
			.liveWhileSettingsLocked()
		}
	}
}
