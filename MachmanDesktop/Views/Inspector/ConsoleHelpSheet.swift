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

	// Type scale: review feedback said the guide read too small — the standard styles'
	// sizes +20% (title3 15→18, callout 12→14.5, caption 10→12).
	private static let titleSize: CGFloat = 18
	private static let textSize: CGFloat = 14.5
	private static let smallSize: CGFloat = 12

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
			.frame(minHeight: 300, maxHeight: 440)
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
		.frame(width: 560)
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
		step(6, "Only an installer ISO? Create a target disk, boot the installer on the "
			+ "same serial console, install onto the empty disk, and apply steps 1–2 "
			+ "before the final reboot (the installer offers a shell) — or boot the new "
			+ "disk as in step 5:")
		command("qemu-img create -f raw freebsd.raw 20G")
		command("qemu-system-aarch64 -machine virt -accel hvf -cpu host -smp 4 -m 4G \\\n"
			+ "  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \\\n"
			+ "  -drive file=freebsd.iso,format=raw,if=virtio,readonly=on \\\n"
			+ "  -drive file=freebsd.raw,format=raw,if=virtio -nographic")
		step(7, "Add the prepared freebsd.raw to this VM as a disk (Copy into VM or "
			+ "Reference), boot, and the login prompt appears in this console.")
		step(8, "Boot hangs? FreeBSD ≤ 15.1 can hang at boot under Apple virtualization "
			+ "while a Display device is attached (its virtio-gpu driver waits forever "
			+ "for a reply the host never sends). Disable this VM's Display device and "
			+ "boot again.")
	}

	// MARK: - macOS guest

	@ViewBuilder
	private var macOSSteps: some View {
		intro("On a macOS guest this port is /dev/cu.virtio\(macSuffix) (with a matching "
			+ "/dev/tty.virtio\(macSuffix)). macOS starts no login prompt on it — a fresh "
			+ "console stays blank.")
		step(1, "Quick test — in the guest's Terminal:")
		command("echo hello > /dev/cu.virtio\(macSuffix)")
		note("The text appears in this console; cat /dev/cu.virtio\(macSuffix) prints "
			+ "what you type here.")
		step(2, "Login prompt — append a getty line to /etc/ttys in the guest (needs "
			+ "sudo), then reboot the guest:")
		command("tty.virtio\(macSuffix) \"/usr/libexec/getty std.115200\" vt100 on secure")
		note("The first field must match the device under /dev without the /dev/ prefix — "
			+ "check ls /dev/tty.virtio* first.")
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
