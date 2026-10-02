//
//  GuestSetupInspector.swift
//  MachmanDesktopUI
//
//  The unified installer's home (1.0.7): status from the guest's report (detected OS,
//  last run + script version, the errors and notes popdowns), the per-feature list, and
//  the setup commands per boot mode — auto-collapsed behind a checkmark once installed,
//  with an Allow-reinstall toggle to bring them back. Inspector text rule: nothing longer
//  than one sentence — details live in the Setup Guide sheet, never here.
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
	private var lastRunFailed: Bool { setup?.lastRunStatus == "failed" }

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
					.confirmationDialog("Reset guest-setup state?", isPresented: $resetConfirm) {
						Button("Reset", role: .destructive) { viewModel.resetSetup(vm.name) }
						Button("Cancel", role: .cancel) {}
					} message: {
						Text("Forgets the guest's report — the guest keeps what the "
							+ "script installed, and SSH state has its own reset.")
					}
			}
			if let device {
				DeviceImplementationSection(vm: vm, device: device)
				DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .guestSetup)
			}
		}
		.sheet(isPresented: $showGuide) {
			GuestSetupHelpSheet(vm: vm)
		}
	}

	// MARK: - Status

	private var statusSection: some View {
		Section("Status") {
			LabeledContent("Install status") { statusLabel }
			// While setup is (re)installable the row says what a run will find — the
			// share already automounted (and how) or merely available. Installed and
			// collapsed, the ephemeral-payload lifecycle line returns.
			if installed && !allowReinstall && !lastRunFailed {
				// Not serving: the reserved dirs ride the share EMPTY (content only
				// while installing — the toggle below brings it back).
				LabeledContent("Payload") {
					Text("not served — the share stays clean")
						.foregroundStyle(.secondary)
				}
			} else {
				LabeledContent("Share") {
					Text(shareTransport).foregroundStyle(.secondary)
				}
			}
			if let setup, installed {
				if let os = setup.guestOS {
					let version = setup.guestOSVersion.map { " \($0)" } ?? ""
					let initSystem = setup.guestInit.map { ", \($0)" } ?? ""
					LabeledContent("Guest") {
						Text("\(os)\(version)\(initSystem)")
							.font(.system(.callout, design: .monospaced))
					}
				}
				if let at = setup.lastReportAt {
					LabeledContent("Last run") {
						Text(at.formatted(date: .abbreviated, time: .shortened))
					}
				}
				if let version = setup.scriptVersion {
					LabeledContent("Script") {
						HStack(spacing: 5) {
							Text("v\(version)")
							if let current = setup.currentScriptVersion, current > version {
								Text("v\(current) available — re-run to update")
									.font(.caption)
									.foregroundStyle(MachmanColors.warning)
							}
						}
					}
				}
				if let transport = setup.lastTransport {
					LabeledContent("Transport", value: transport)
				}
				errorsPopdown
				notesPopdown
			} else {
				Text("No report yet — run the install script in the guest.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	// What carries the share into the guest: "virtiofs auto" / "sshfs auto" when the
	// guest automounts it, else "available" — served, mount by hand.
	private var shareTransport: String {
		let automounts = setup?.automounts ?? []
		if automounts.contains(where: { $0.kind == MountKind.virtiofs }) {
			return "virtiofs auto"
		}
		if automounts.contains(where: { $0.kind == MountKind.sshfs && $0.target == "@share" }) {
			return "sshfs auto"
		}
		return "available"
	}

	private var statusLabel: some View {
		HStack(spacing: 5) {
			switch (installed, setup?.lastRunStatus) {
			case (false, _):
				Text("Not installed").foregroundStyle(.secondary)
			case (true, "partial"):
				Image(systemName: MachmanSymbols.warning)
					.foregroundStyle(MachmanColors.warning)
				Text("Installed, with gaps")
			case (true, "failed"):
				Image(systemName: MachmanSymbols.warning)
					.foregroundStyle(MachmanColors.warning)
				Text("Last run failed")
			default:
				Label("Installed", systemImage: MachmanSymbols.activeEntry)
					.foregroundStyle(MachmanColors.stateRunning)
			}
		}
	}

	@ViewBuilder
	private var errorsPopdown: some View {
		if let errors = setup?.errors, !errors.isEmpty {
			DisclosureGroup("Errors (\(errors.count))") {
				reportLines(errors)
			}
		}
	}

	// What the run noted without failing (a repair it made, a boot refresh that won't run).
	@ViewBuilder
	private var notesPopdown: some View {
		if let notes = setup?.notes, !notes.isEmpty {
			DisclosureGroup("Notes (\(notes.count))") {
				reportLines(notes)
			}
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
								Text(feature.reason ?? "not available on this guest")
									.font(.caption)
									.foregroundStyle(.secondary)
									.fixedSize(horizontal: false, vertical: true)
							}
						}
					}
				}
			}
		}
	}

	private func featureSummary(_ feature: GuestFeatureInfo) -> String {
		guard feature.configured else { return "not configured" }
		return feature.detail ?? "configured"
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
			// The serve boundary, stated where it is decided: on = filled live, off =
			// content leaves with the run (never yanked from under the guest).
			if installed, vm.state.isRunning {
				Text(allowReinstall || lastRunFailed
					? "Serving — the installer is in the share."
					: "Not serving — clears at shutdown if present.")
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

	// The share automounts (either transport): mounting instructions would contradict
	// the Share row above, so the run command stands alone.
	private var shareAutomounted: Bool { shareTransport != "available" }

	@ViewBuilder
	private var setupCommands: some View {
		switch vm.boot.mode {
		case .macOS:
			Text("Run in the guest's Terminal (the share automounts, macOS 13+):")
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
			DisclosureGroup("FreeBSD / OpenBSD") {
				VStack(alignment: .leading, spacing: 6) {
					Text(shareAutomounted
						? "The share automounts over ssh — run the installer:"
						: "No virtiofs driver — the guide shows the one-time sshfs "
							+ "bootstrap; afterwards the same run command applies.")
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					CommandBlock(GuestSetupCommands.run(.bsd, shareMounted: true))
				}
				.padding(.vertical, 2)
			}
		}
	}
}
