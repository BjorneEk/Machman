//
//  ConsoleHelpSheet.swift
//  MachmanDesktop
//
//  The console Setup Guide: how to get a login prompt (and boot output) on a virtio
//  console inside the guest. EFI VMs get Linux + FreeBSD tabs (the guest could be either);
//  macOS VMs a single page. Every step runs INSIDE the guest and edits are append-only —
//  the footer says so on every page. Content sources: the serial research findings (Linux,
//  measured) and the FreeBSD console prep measured on the FreeBSD-under-VZ stint.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct ConsoleHelpSheet: View {
	let mode: BootInfo.Mode
	let guestIndex: Int
	@Environment(\.dismiss) private var dismiss
	@State private var tab: GuestTab = .linux

	private enum GuestTab: String, CaseIterable {
		case linux = "Linux"
		case freebsd = "FreeBSD"
	}

	// "cu.virtio" for port 0, "cu.virtio2" beyond — mirrors the device naming rule.
	private var macSuffix: String { guestIndex == 0 ? "" : "\(guestIndex)" }
	private var portLabel: String {
		SerialPortKind.console.displayName(guestIndex: guestIndex, mode: mode)
	}

	// Type scale: review feedback twice said the guides read too small — the standard
	// styles' sizes roughly +25-30% by now (title3 15→19, callout 12→15.5, caption 10→13).
	private static let titleSize: CGFloat = 19
	private static let textSize: CGFloat = 15.5
	private static let smallSize: CGFloat = 13

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 8) {
				Image(systemName: MachmanSymbols.help)
					.font(.system(size: 24))
					.foregroundStyle(.secondary)
				Text("Console Setup — \(portLabel)")
					.font(.system(size: Self.titleSize, weight: .semibold))
				Spacer()
			}
			if mode == .efi {
				Picker("Guest OS", selection: $tab) {
					ForEach(GuestTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 12) {
					switch (mode, tab) {
					case (.macOS, _): macOSSteps
					case (_, .linux): linuxSteps
					case (_, .freebsd): freebsdSteps
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, 2)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			Divider()
			HStack(alignment: .firstTextBaseline) {
				Text(footerText)
					.font(.system(size: Self.smallSize))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		// FIXED size on purpose: a min/max-height ScrollView inside a sheet makes the
		// AppKit hosting view renegotiate during layout (_NSDetectedLayoutRecursion).
		.frame(width: 560, height: 620)
	}

	// The FreeBSD tab's QEMU steps are the one place commands run on the Mac (Homebrew +
	// booting the image in your terminal) — the blanket claim would be wrong there.
	private var footerText: String {
		if mode == .efi && tab == .freebsd {
			return "Steps 1–3 run inside the virtual machine; the QEMU route runs in your "
				+ "Mac's terminal and only touches the disk image you point it at."
		}
		return "All commands run inside the virtual machine — nothing on your Mac is "
			+ "modified."
	}

	// MARK: - Linux (EFI + the guide is never shown for kernel boots)

	@ViewBuilder
	private var linuxSteps: some View {
		intro("On Linux this port is /dev/hvc\(guestIndex) (virtio console — built into "
			+ "virtually every distribution).")
		if guestIndex == 0 {
			step(1, "Login prompt — most distributions need nothing: systemd starts a "
				+ "login on hvc0 automatically as soon as the device exists. If no prompt "
				+ "appears:")
		} else {
			step(1, "Login prompt — systemd auto-starts one only on hvc0; enable it for "
				+ "this port:")
		}
		command("sudo systemctl enable --now serial-getty@hvc\(guestIndex).service")
		note("OpenRC (Alpine) has no systemctl — add a getty line to /etc/inittab instead:")
		command("echo 'hvc\(guestIndex)::respawn:/sbin/getty 38400 hvc\(guestIndex)' "
			+ ">> /etc/inittab && kill -HUP 1")
		step(2, "Boot messages (one-time) — add console=hvc\(guestIndex) to the kernel "
			+ "command line: in the VM's display window, at the GRUB menu press E, append "
			+ "it to the line starting with “linux”, then press Ctrl-X to boot. Works on "
			+ "install ISOs too.")
		command("console=hvc\(guestIndex)")
		step(3, "Make it permanent (installed system) — append the same option to "
			+ "GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, regenerate and reboot:")
		command("sudo update-grub")
		note("Fedora/RHEL: sudo grub2-mkconfig -o /boot/grub2/grub.cfg")
	}

	// MARK: - FreeBSD (EFI)

	@ViewBuilder
	private var freebsdSteps: some View {
		intro("On FreeBSD this port is /dev/ttyV\(guestIndex).0. It cannot carry loader or "
			+ "kernel boot messages — it comes up once the system is running (login "
			+ "prompt only).")
		step(1, "Load the driver — it is not loaded by default. Append to "
			+ "/boot/loader.conf (as root) and reboot, or kldload virtio_console for the "
			+ "running system:")
		command("virtio_console_load=\"YES\"")
		step(2, "Start a login prompt — append this line to /etc/ttys, then make init "
			+ "re-read it:")
		command("ttyV\(guestIndex).0 \"/usr/libexec/getty std.9600\" vt100 onifexists secure")
		command("kill -HUP 1")
		step(3, "Root login refused with the correct password? FreeBSD only allows root on "
			+ "terminals marked “secure” in /etc/ttys — the line above includes it. "
			+ "Regular users can log in either way.")
		step(4, "No shell to type any of this into? That's the catch-22: the console only "
			+ "works after steps 1–2, and this Mac's virtualization gives FreeBSD no "
			+ "other serial path. Prepare the disk on your Mac instead — under QEMU, "
			+ "FreeBSD boots with a fully working serial console in your terminal:")
		command("brew install qemu")
		step(5, "Have a .raw image already (FreeBSD's official …-arm64-aarch64 VM images "
			+ "work too)? Boot it, log in as root on the console, apply steps 1–2, then "
			+ "shutdown -p now. Exit QEMU with Ctrl-A, then X:")
		command("qemu-system-aarch64 -machine virt -accel hvf -cpu host -smp 4 -m 4G \\\n"
			+ "  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \\\n"
			+ "  -drive file=freebsd.raw,format=raw,if=virtio -nographic")
		step(6, "Only an installer ISO? Create this VM's disk first — Add (+) → Disk — "
			+ "then right-click the disk row and Copy Path. Boot the installer with that "
			+ "path as the target, install onto the empty disk, and apply steps 1–2 "
			+ "before the final reboot (the installer offers a shell):")
		command("qemu-system-aarch64 -machine virt -accel hvf -cpu host -smp 4 -m 4G \\\n"
			+ "  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \\\n"
			+ "  -drive file=freebsd.iso,format=raw,if=virtio,readonly=on \\\n"
			+ "  -drive file=<paste the copied path>,format=raw,if=virtio -nographic")
		note("Machman disks are plain raw images, so QEMU installs straight into the VM's "
			+ "own disk — nothing to import afterwards. Keep the VM stopped meanwhile.")
		step(7, "Came from step 5 with an external .raw? Add it to this VM as a disk "
			+ "(Copy into VM or Reference). Then boot — the login prompt appears in this "
			+ "console.")
		step(8, "Boot hangs? FreeBSD ≤ 15.1 can hang at boot under Apple virtualization "
			+ "while a Display device is attached (its virtio-gpu driver waits forever "
			+ "for a reply the host never sends). Disable this VM's Display device and "
			+ "boot again.")
	}

	// MARK: - macOS guest

	// The Console Login flow (measured recipe: a launchd getty with KeepAlive; /etc/ttys
	// getty lines are DEAD on modern macOS — launchd ignores them).
	@ViewBuilder
	private var macOSSteps: some View {
		intro("On a macOS guest this port is /dev/cu.virtio\(macSuffix). macOS starts no "
			+ "login prompt on it — the Console Login installer sets one up on every "
			+ "console in a single run.")
		step(1, "Add the Console Login installer: Add (+) → Installers → Console Login.")
		step(2, "Boot the guest — the “My Shared Files” volume appears on its own "
			+ "(macOS 13+ guests) with a \(ConsoleLoginInstallerInfo.directoryName) "
			+ "folder inside, next to this VM's regular mounts.")
		step(3, "In the guest's Terminal, run the script and enter your password:")
		command(ConsoleLoginInstallerInfo.runCommand)
		note("It checks every console device and installs a login daemon for each — "
			+ "prompts appear in the Machman consoles immediately, no reboot needed.")
		step(4, "Afterwards: disable or remove the Console Login device — the logins "
			+ "live in the guest and persist. Re-enable it, reboot, and re-run after "
			+ "adding or removing consoles (the script also cleans up removed ones); "
			+ "run it with --uninstall to remove every login.")
		step(5, "Troubleshooting — port I/O works even without a login: in the guest, "
			+ "echo hello > /dev/cu.virtio\(macSuffix) prints in this console. Volume "
			+ "missing (macOS 12 guests)? Mount it manually, then run from ~/shared:")
		command(ConsoleLoginInstallerInfo.fallbackMountCommand)
	}

	// MARK: - Building blocks

	private func intro(_ text: String) -> some View {
		Text(text)
			.font(.system(size: Self.textSize))
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
	}

	private func step(_ number: Int, _ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("\(number)")
				.font(.system(size: Self.smallSize, weight: .semibold))
				.monospacedDigit()
				.frame(width: 20, height: 20)
				.background(Circle().fill(Color.primary.opacity(0.08)))
			Text(text)
				.font(.system(size: Self.textSize))
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func command(_ cmd: String) -> some View {
		HStack {
			Text(cmd)
				.font(.system(size: Self.smallSize, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 6)
			CopyToClipboardButton(cmd, tooltip: "Copy")
		}
		.padding(7)
		.background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
		.padding(.leading, 28)
	}

	private func note(_ text: String) -> some View {
		Text(text)
			.font(.system(size: Self.smallSize))
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.leading, 28)
	}
}
