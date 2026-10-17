//
//  VMDevices.swift
//  Machman
//
//  VZ device construction for VMConfig, split out from the model. The boot-mode-aware builders
//  (makePlatform / makeBootLoader / graphicsDevices / keyboards / pointingDevices) are the seam
//  where a new boot mode plugs in: add a BootConfig case (and its coding key), then one arm in
//  each switch here.
//

import Foundation
import Virtualization
import AppKit
import MachmanAPI

// The host ends of one serial port's pipes, handed to a SerialPortBridge. The VZ attachment holds
// the other ends. The bridge writes guest input to `toGuest` and reads guest output from
// `fromGuest`.
struct SerialWiring {
	let kind: SerialPortKind
	let index: Int
	let toGuest: FileHandle
	let fromGuest: FileHandle
}

// A built VZ configuration plus the serial pipe wiring its ports need bridged, plus human
// warnings for configured devices the builder had to skip (host gates, boot-mode misfits).
struct BuiltVM {
	let configuration: VZVirtualMachineConfiguration
	let serialWiring: [SerialWiring]
	let warnings: [String]
}

extension VMConfig {

	// MARK: - Boot-mode-aware builders

	// A start's first check (C11): a boot mode a newer Machman wrote never boots here — this
	// build can't know what it needs. Neither does kernel boot with no kernel chosen (D37): it
	// is refused with what to do. The assembly below runs it before anything else, and the
	// router runs it before any vmhost is launched.
	func requireStartableBoot() throws {
		if case .unknown = boot { throw BootConfig.newerModeRefusal }
		if case .linuxKernel(let kernel) = boot, kernel.kernelPath.isEmpty {
			throw noKernelRefusal
		}
	}

	// The empty draft kernel boot starts from failed as "Kernel image not found: " (D37).
	var noKernelRefusal: MachmanError {
		MachmanError(
			code: .invalidState, message: "Choose a kernel for \(name) before starting it")
	}

	func makePlatform() throws -> VZPlatformConfiguration {
		switch boot {
		case .efi, .linuxKernel:
			let platform = VZGenericPlatformConfiguration()
			platform.machineIdentifier = try getVmIdentifier()
			return platform
		case .macOS:
			let platform = VZMacPlatformConfiguration()
			platform.hardwareModel = try getMacHardwareModel()
			platform.machineIdentifier = try getMacMachineIdentifier()
			platform.auxiliaryStorage = try getMacAuxiliaryStorage()
			return platform
		case .unknown:
			throw BootConfig.newerModeRefusal
		}
	}

	func makeBootLoader() throws -> VZBootLoader {
		switch boot {
		case .efi:
			let loader = VZEFIBootLoader()
			loader.variableStore = try getEFIVariableStore()
			return loader
		case .linuxKernel(let k):
			guard !k.kernelPath.isEmpty else { throw noKernelRefusal }
			guard FileManager.default.fileExists(atPath: k.kernelPath) else {
				throw VirtualMachineError.critical("Kernel image not found: \(k.kernelPath)")
			}
			let loader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: k.kernelPath))
			// The initramfs is checked like the kernel — a moved one surfaced as VZ's generic
			// start error — and "" names none: it read as the working directory (D37).
			if let initrd = k.initialRamdiskPath, !initrd.isEmpty {
				guard FileManager.default.fileExists(atPath: initrd) else {
					throw VirtualMachineError.critical("Initramfs not found: \(initrd)")
				}
				loader.initialRamdiskURL = URL(fileURLWithPath: initrd)
			}
			loader.commandLine = effectiveKernelCommandLine(for: k)
			return loader
		case .macOS:
			return VZMacOSBootLoader()
		case .unknown:
			throw BootConfig.newerModeRefusal
		}
	}

	// MARK: - Config-driven device resolution (1.0.4)

	// The devices that actually attach at this start: the configured list minus disabled
	// entries (silently honored — that's what disabling means) minus entries this host or
	// boot mode cannot carry (warned, so the user learns the VM started with fewer devices).
	// A warning is one sentence without the VM's name: the desktop shows it as "<VM>: …".
	func resolvedDevices() -> (attach: [DeviceKind: GuestDevice], warnings: [String]) {
		var attach: [DeviceKind: GuestDevice] = [:]
		var warnings: [String] = []
		let macGuest: Bool = { if case .macOS = boot { return true }; return false }()
		for device in devices {
			guard device.enabled else { continue }
			switch device.deviceKind {
			case .unknown:
				warnings.append(
					"A newer Machman added the device \u{201C}\(device.kind)\u{201D}, so it "
						+ "isn’t attached.")
			case .trackpad where !macGuest:
				warnings.append("The Mac trackpad needs a macOS guest, so it isn’t attached.")
			case .clipboard where macGuest:
				warnings.append(
					"Clipboard sharing isn’t supported for macOS guests, so it isn’t attached.")
			case .rosetta where macGuest:
				warnings.append(
					"Rosetta isn’t supported for macOS guests, so it isn’t attached.")
			case .rosetta where VZLinuxRosettaDirectoryShare.availability != .installed:
				warnings.append("Rosetta isn’t installed on this Mac, so it isn’t attached.")
			case let kind:
				attach[kind] = device
			}
		}
		return (attach, warnings)
	}

	// One warning per tag that more than one shared mount carries: only the first of them is
	// shared (directoryShareDeviceConfig). Worded like resolvedDevices' warnings.
	func shareTagWarnings() -> [String] {
		var counts: [String: Int] = [:]
		var order: [String] = []
		for mount in sharedMounts {
			if counts[mount.tag] == nil { order.append(mount.tag) }
			counts[mount.tag, default: 0] += 1
		}
		return order.compactMap { tag in
			guard let count = counts[tag], count > 1 else { return nil }
			let mounts = count == 2 ? "Two mounts" : "\(count) mounts"
			return "\(mounts) share the tag \u{201C}\(tag)\u{201D}, so only the first is shared."
		}
	}

	// Generic (virtio / USB) graphics for EFI/Linux; Mac graphics for a macOS guest.
	// Resolution comes from the device's settings, falling back to the host screen size
	// (and 80 ppi for Mac guests) — exactly the pre-1.0.4 hard-coded behavior.
	func graphicsDevices(for device: GuestDevice?) -> [VZGraphicsDeviceConfiguration] {
		guard let device else { return [] }
		let fallback = VMConfig.mainScreenSize(2560, 1440)
		let width = device.displayWidthPixels ?? fallback.width
		let height = device.displayHeightPixels ?? fallback.height
		switch boot {
		case .efi, .linuxKernel, .unknown:   // .unknown never starts (requireStartableBoot)
			let graphics = VZVirtioGraphicsDeviceConfiguration()
			graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
				widthInPixels: width, heightInPixels: height)]
			return [graphics]
		case .macOS:
			let graphics = VZMacGraphicsDeviceConfiguration()
			graphics.displays = [VZMacGraphicsDisplayConfiguration(
				widthInPixels: width, heightInPixels: height,
				pixelsPerInch: device.displayPixelsPerInch ?? 80)]
			return [graphics]
		}
	}

	// The Mac keyboard/trackpad classes need a macOS guest; EFI/Linux get USB variants.
	// The kind resolves to the boot-appropriate class here, so device lists survive
	// boot-mode changes unedited.
	func keyboards(present: Bool) -> [VZKeyboardConfiguration] {
		guard present else { return [] }
		switch boot {
		case .efi, .linuxKernel, .unknown:   // .unknown never starts (requireStartableBoot)
			return [VZUSBKeyboardConfiguration()]
		case .macOS:
			return [VZMacKeyboardConfiguration()]
		}
	}

	// trackpad and pointer are separate devices since 1.0.4 (the engine used to always pair
	// them for mac guests — the implied set still does; users can now drop either).
	func pointingDevices(trackpad: Bool, pointer: Bool) -> [VZPointingDeviceConfiguration] {
		var out: [VZPointingDeviceConfiguration] = []
		if trackpad { out.append(VZMacTrackpadConfiguration()) }
		if pointer { out.append(VZUSBScreenCoordinatePointingDeviceConfiguration()) }
		return out
	}

	// allowSharing false (the lab device policy) keeps the spice port but never shares the
	// clipboard, whatever the device says.
	func consoleDevices(
		clipboard device: GuestDevice?, allowSharing: Bool = true
	) -> [VZConsoleDeviceConfiguration] {
		guard let device else { return [] }
		return [VMConfig.spiceAgentConsoleDeviceConfig(
			sharesClipboard: allowSharing && (device.sharesClipboard ?? true))]
	}

	// Rosetta rides as an EXTRA directory-sharing device with the well-known "rosetta" tag,
	// separate from the "host-share" multi-share. Availability is pre-checked in
	// resolvedDevices(); a throw here still degrades to a warning at the call site.
	func rosettaShareDeviceConfig() throws -> VZVirtioFileSystemDeviceConfiguration {
		let share = try VZLinuxRosettaDirectoryShare()
		let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
		device.share = share
		return device
	}

	// Build the configured serial ports over fresh pipe pairs, returning the host-end wiring for
	// the bridges. Console (virtio) ports come first so a Linux guest numbers them hvc0.. and the
	// PL011 uart ports ttyAMA0.. by their own order. Each pipe MUST be drained by a bridge or the
	// guest stalls writing to it.
	func serialPorts() -> (ports: [VZSerialPortConfiguration], wiring: [SerialWiring]) {
		var ports: [VZSerialPortConfiguration] = []
		var wiring: [SerialWiring] = []
		// Disabled ports (1.0.4) are skipped like removed ones — the guest numbers the rest
		// compactly; wiring keeps the CONFIG index so sockets/logs stay stably keyed.
		for index in consolePorts.indices where consolePorts[index].enabled {
			let (attachment, wire) = makeSerialPipe(kind: .console, index: index)
			let port = VZVirtioConsoleDeviceSerialPortConfiguration()
			port.attachment = attachment
			ports.append(port)
			wiring.append(wire)
		}
		let enabledUarts = uartPorts.indices.filter { uartPorts[$0].enabled }
		let uartIssue = enabledUarts.isEmpty ? nil : VMConfig.uartUnavailability()
		for index in enabledUarts {
			guard let port = makePL011SerialPort() else {
				MachmanLogger.log(.passiveWarning, "skipping uart\(index) on \(name): "
					+ (uartIssue?.message ?? "the private PL011 class is unavailable"))
				continue
			}
			let (attachment, wire) = makeSerialPipe(kind: .uart, index: index)
			port.attachment = attachment
			ports.append(port)
			wiring.append(wire)
		}
		return (ports, wiring)
	}

	private func makeSerialPipe(
		kind: SerialPortKind, index: Int
	) -> (VZFileHandleSerialPortAttachment, SerialWiring) {
		let toGuest = Pipe()
		let fromGuest = Pipe()
		let attachment = VZFileHandleSerialPortAttachment(
			fileHandleForReading: toGuest.fileHandleForReading,
			fileHandleForWriting: fromGuest.fileHandleForWriting)
		let wire = SerialWiring(
			kind: kind, index: index,
			toGuest: toGuest.fileHandleForWriting, fromGuest: fromGuest.fileHandleForReading)
		return (attachment, wire)
	}

	// The private PL011 UART class (a real /dev/ttyAMA* in the guest, drivable by bare-metal
	// kernels). Present in every SDK since macOS 11; usable with only the public virtualization
	// entitlement up to macOS 26.6.0, gated since 26.6.1 (privateSerialRejected below). Private,
	// so guard it and skip cleanly if it ever disappears.
	private func makePL011SerialPort() -> VZSerialPortConfiguration? {
		guard !VMConfig.privateSerialRejected() else { return nil }
		guard let cls = NSClassFromString("_VZPL011SerialPortConfiguration") as? NSObject.Type,
			let port = cls.perform(NSSelectorFromString("new"))?.takeRetainedValue()
				as? VZSerialPortConfiguration else {
			return nil
		}
		return port
	}

	// macOS 26.6.1's security update reclassified the private serial devices (PL011 AND 16550) as
	// "restricted devices" gated behind the com.apple.private.virtualization entitlement: the
	// classes still exist and validate, but the com.apple.Virtualization.VirtualMachine helper
	// traps ("Restricted devices require the com.apple.private.virtualization entitlement.") for an
	// unentitled caller, so EVERY start of a VM carrying one fails with an opaque VZErrorInternal.
	// That entitlement is com.apple.private.* — honoured only for Apple-signed binaries or with SIP
	// disabled + amfi_get_out_of_my_way=1; carrying it on a SIP-on machine SIGKILLs EVERY VZ start
	// (measured), so we must never add it by default. Machman stays unentitled, so on ≥ 26.6.1 a
	// VM must start even if its uarts cannot. Measured 2026-08-13 on 26.6.1 (25G76); 26.6.0 worked.
	// Reproducer: docs/local/socket-research/05-uart-availability.swift.
	static func privateSerialRejected(
		by v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
	) -> Bool {
		let g = SerialPortSupport.privateUARTGatedSince
		return (v.majorVersion, v.minorVersion, v.patchVersion)
			>= (g.majorVersion, g.minorVersion, g.patchVersion)
	}

	// The reason a uart (private PL011) port cannot be attached on this host, or nil if uarts work
	// here. The single source for the VZ-builder skip log, the start-time warning event, and the
	// wire's SerialPortInfo.unavailable — so a client that queries a VM learns exactly why a
	// configured uart is inert. Checks the macOS version gate first, then the class's presence.
	// The message is user text (an inspector, a toast, a tooltip): one sentence that names UART
	// ports, never the entitlement id (com.apple.private.virtualization, see above).
	static func uartUnavailability(
		gated: Bool = VMConfig.privateSerialRejected(),
		classPresent: Bool = NSClassFromString("_VZPL011SerialPortConfiguration") != nil
	) -> SerialPortUnavailability? {
		if gated {
			let since = SerialPortSupport.privateUARTGatedSinceDisplay
			return SerialPortUnavailability(
				reason: .privateUARTGated,
				message: "Since macOS \(since), only Apple’s own apps can attach UART ports, so "
					+ "VMs start without them.",
				sinceOSVersion: since)
		}
		if !classPresent {
			return SerialPortUnavailability(
				reason: .classUnavailable,
				message: "This version of macOS has no UART device, so VMs start without UART "
					+ "ports.")
		}
		return nil
	}

	// Assembles the full VZ configuration from the persisted device list (1.0.4). Shared by
	// the normal boot path (VirtualMachine) and the macOS installer so the device list lives
	// in exactly one place. attachSerial is false for the installer: it does not run bridges,
	// and an undrained serial pipe would stall the guest. Under a test suite the lab device
	// policy drops what would reach the host, after resolution: its drops are no warnings,
	// which become events and toasts.
	func makeVZVirtualMachineConfiguration(
		attachSerial: Bool = true, lab: LabEnvironment? = .current
	) throws -> BuiltVM {
		let built = try assembleVZConfiguration(attachSerial: attachSerial, lab: lab)
		do {
			try built.configuration.validate()
		} catch {
			// User-editable devices make validate() the primary failure path — surface a
			// readable machmanCode'd message instead of leaking "Error Domain=VZErrorDomain…".
			let ns = error as NSError
			if ns.domain == VZError.errorDomain {
				throw MachmanError(
					code: .virtualizationFailure,
					message: "\(name) can’t start with its current settings: "
						+ MachmanError.userMessage(for: error))
			}
			throw error
		}
		return built
	}

	// The configuration before VZ validates it (which takes the virtualization entitlement, so
	// the headless tests stop here).
	func assembleVZConfiguration(attachSerial: Bool, lab: LabEnvironment?) throws -> BuiltVM {
		try requireStartableBoot()
		let resolved = resolvedDevices()
		let policy = LabDevicePolicy.current(lab: lab)
		var byKind = resolved.attach
		if let policy {
			let applied = policy.apply(byKind)
			byKind = applied.kept
			if !applied.dropped.isEmpty {
				MachmanLogger.log(.log, "test mode: \(name) starts without "
					+ "\(LabDevicePolicy.describe(applied.dropped)) (lab device policy)")
			}
		}
		var warnings = resolved.warnings
		let vmConfig = VZVirtualMachineConfiguration()
		vmConfig.cpuCount = effectiveCPUCount
		vmConfig.memorySize = effectiveMemorySize
		vmConfig.platform = try makePlatform()
		vmConfig.bootLoader = try makeBootLoader()
		vmConfig.storageDevices = try diskArray()
		vmConfig.networkDevices = byKind[.network] != nil ? [networkDeviceConfig()] : []
		vmConfig.graphicsDevices = graphicsDevices(for: byKind[.graphics])
		var audio: [VZAudioDeviceConfiguration] = []
		if byKind[.audioInput] != nil { audio.append(VMConfig.inputAudioDeviceConfig()) }
		if byKind[.audioOutput] != nil { audio.append(VMConfig.outputAudioDeviceConfig()) }
		vmConfig.audioDevices = audio
		vmConfig.keyboards = keyboards(present: byKind[.keyboard] != nil)
		vmConfig.pointingDevices = pointingDevices(
			trackpad: byKind[.trackpad] != nil, pointer: byKind[.pointer] != nil)
		vmConfig.consoleDevices = consoleDevices(
			clipboard: byKind[.clipboard], allowSharing: policy?.sharesClipboard ?? true)
		if byKind[.entropy] != nil {
			vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
		}
		var wiring: [SerialWiring] = []
		if attachSerial {
			let serial = serialPorts()
			vmConfig.serialPorts = serial.ports
			wiring = serial.wiring
		}
		// macOS guests automount the share at /Volumes/My Shared Files (one subdirectory
		// per mount tag); other guests keep mounting the "host-share" tag by hand.
		let macGuest: Bool = { if case .macOS = boot { return true }; return false }()
		let shareTag = macGuest
			? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
			: GuestPaths.shareTag
		var extraShares: [String: VZSharedDirectory] = [:]
		if byKind[.guestSetup] != nil {
			// Any guest: read-only payload beside a writable report drop-box, both riding
			// the one share device (reserved names; readOnly is per-directory). A writable
			// script would let any guest process swap it before the admin sudo-runs it.
			// The directories are ALWAYS registered — serving decides their content, so
			// the toggle never needs live device changes (vm.setup.serve fills in place).
			do {
				let (payload, report) = try servesSetupPayload
					? GuestSetupInstaller.writePayload(for: self)
					: GuestSetupInstaller.ensurePayloadDirectories(for: self)
				extraShares[GuestSetupInstaller.directoryName] =
					VZSharedDirectory(url: payload, readOnly: true)
				extraShares[GuestSetupInstaller.reportDirectoryName] =
					VZSharedDirectory(url: report, readOnly: false)
			} catch {
				warnings.append(
					"Guest Setup isn’t attached: \(MachmanError.userMessage(for: error))")
			}
		}
		warnings += shareTagWarnings()
		var shares: [VZDirectorySharingDeviceConfiguration] =
			[directoryShareDeviceConfig(mainTag: shareTag, extraDirectories: extraShares)]
		if byKind[.rosetta] != nil {
			do {
				shares.append(try rosettaShareDeviceConfig())
			} catch {
				warnings.append(
					"Rosetta isn’t attached: \(MachmanError.userMessage(for: error))")
			}
		}
		vmConfig.directorySharingDevices = shares
		if nestedVirtualization {
			if let generic = vmConfig.platform as? VZGenericPlatformConfiguration,
				VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
				generic.isNestedVirtualizationEnabled = true
			} else {
				warnings.append(
					"Nested virtualization isn’t supported on this Mac or for this boot mode, "
						+ "so it’s off.")
			}
		}
		return BuiltVM(configuration: vmConfig, serialWiring: wiring, warnings: warnings)
	}

	// MARK: - Device factories

	func networkDeviceConfig() -> VZVirtioNetworkDeviceConfiguration {
		let networkDevice = VZVirtioNetworkDeviceConfiguration()
		networkDevice.attachment = VZNATNetworkDeviceAttachment()
		networkDevice.macAddress = getOrCreateMACAddress()
		return networkDevice
	}

	static func mainScreenSize(_ defaultWidth: Int, _ defaultHeight: Int) -> (width: Int, height: Int) {
		var width = defaultWidth
		var height = defaultHeight
		if let mainScreen = NSScreen.main {
			width = Int(mainScreen.frame.width)
			height = Int(mainScreen.frame.height)
		}
		return (width: width, height: height)
	}

	static func inputAudioDeviceConfig() -> VZVirtioSoundDeviceConfiguration {
		let inputAudioDevice = VZVirtioSoundDeviceConfiguration()
		let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
		inputStream.source = VZHostAudioInputStreamSource()
		inputAudioDevice.streams = [inputStream]
		return inputAudioDevice
	}

	static func outputAudioDeviceConfig() -> VZVirtioSoundDeviceConfiguration {
		let outputAudioDevice = VZVirtioSoundDeviceConfiguration()
		let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
		outputStream.sink = VZHostAudioOutputStreamSink()
		outputAudioDevice.streams = [outputStream]
		return outputAudioDevice
	}

	static func spiceAgentConsoleDeviceConfig(
		sharesClipboard: Bool = true
	) -> VZVirtioConsoleDeviceConfiguration {
		let consoleDevice = VZVirtioConsoleDeviceConfiguration()

		let spiceAgentPort = VZVirtioConsolePortConfiguration()
		spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
		let attachment = VZSpiceAgentPortAttachment()
		// Explicit now (1.0.4): the framework default is true, but the setting is user-facing.
		attachment.sharesClipboard = sharesClipboard
		spiceAgentPort.attachment = attachment
		consoleDevice.ports[0] = spiceAgentPort

		return consoleDevice
	}

	private func createVmIdentifier(_ vmIdentifierPath: String) throws -> VZGenericMachineIdentifier {
		let machineIdentifier = VZGenericMachineIdentifier()

		// Store the machine identifier to disk so you can retrieve it for subsequent boots.
		do {
			try machineIdentifier.dataRepresentation.write(
				to: URL(fileURLWithPath: vmIdentifierPath), options: .atomic)
		} catch {
			throw VirtualMachineError.critical(
				"Couldn’t save \(name)’s machine identifier: "
					+ MachmanError.userMessage(for: error))
		}
		return machineIdentifier
	}

	func getVmIdentifier() throws -> VZGenericMachineIdentifier {
		let vmIdentifierPath = vmIdentifierPath()
		let fileURL = URL(fileURLWithPath: vmIdentifierPath)

		guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
			return try createVmIdentifier(vmIdentifierPath)
		}
		guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
			throw VirtualMachineError.critical("\(name)’s machine identifier can’t be read")
		}
		return machineIdentifier
	}

	private func createEFIVariableStore(_ efiVarsPath: String) throws -> VZEFIVariableStore {
		do {
			return try VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVarsPath))
		} catch {
			throw VirtualMachineError.critical(
				"Couldn’t create \(name)’s EFI variable store: "
					+ MachmanError.userMessage(for: error))
		}
	}

	func getEFIVariableStore() throws -> VZEFIVariableStore {
		let efiVarsPath = EFIVariableStorePath()
		if !FileManager.default.fileExists(atPath: efiVarsPath) {
			return try createEFIVariableStore(efiVarsPath)
		}

		return VZEFIVariableStore(url: URL(fileURLWithPath: efiVarsPath))
	}

	func getOrCreateMACAddress() -> VZMACAddress {
		if let s = macAddress, let mac = VZMACAddress(string: s) {
			return mac
		}
		let mac = VZMACAddress.randomLocallyAdministered()
		self.macAddress = mac.string
		try? saveVMConfig()
		return mac
	}

	func isoImageDeviceConfig(isoPath: URL) throws -> VZUSBMassStorageDeviceConfiguration {
		let attachment: VZDiskImageStorageDeviceAttachment
		do {
			attachment = try VZDiskImageStorageDeviceAttachment(url: isoPath, readOnly: true)
		} catch {
			throw VirtualMachineError.critical(
				"Couldn’t attach \(isoPath.lastPathComponent): "
					+ MachmanError.userMessage(for: error))
		}
		return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
	}

	func diskDeviceConfig(diskUrl: URL) throws -> VZVirtioBlockDeviceConfiguration {
		let attachment: VZDiskImageStorageDeviceAttachment
		do {
			attachment = try VZDiskImageStorageDeviceAttachment(url: diskUrl, readOnly: false)
		} catch {
			throw VirtualMachineError.critical(
				"Couldn’t attach \(diskUrl.lastPathComponent): "
					+ MachmanError.userMessage(for: error))
		}
		return VZVirtioBlockDeviceConfiguration(attachment: attachment)
	}

	// Disabled entries (1.0.4) stay configured but are not attached.
	func diskArray() throws -> [VZStorageDeviceConfiguration] {
		return try disks.filter(\.enabled).map {
			switch $0.kind {
			case .iso(let url):
				return try self.isoImageDeviceConfig(isoPath: url)
			case .storage(let name, _):
				return try self.diskDeviceConfig(diskUrl: self.localURL(file: "\(name).raw"))
			case .fromUrl(let url):
				return try self.diskDeviceConfig(diskUrl: url)
			}
		}
	}

	// The mounts that ride the share device: the enabled virtiofs ones. sshfs-kind mounts
	// (1.0.7) never enter the share — the guest mounts them itself over its SSH link (the
	// payload's mounts.list carries them there instead).
	var sharedMounts: [HostMountPoint] {
		mountPoints.filter { $0.enabled && $0.kind != MountKind.sshfs }
	}

	func directoryShareDeviceConfig(
		mainTag: String, extraDirectories: [String: VZSharedDirectory] = [:]
	) -> VZVirtioFileSystemDeviceConfiguration {
		// A doubled tag shares its first mount (D25): add and rename refuse doubles, but a
		// config from before that, or edited by hand, still loads (names are validated at
		// entry, never at load) — and a trap here killed the vmhost at every start.
		// shareTagWarnings tells the user.
		var sharedDirectories: [String: VZSharedDirectory] = Dictionary(
			sharedMounts.map { mount in
				(mount.tag,
				VZSharedDirectory(url: URL(fileURLWithPath: mount.path), readOnly: false))
			},
			uniquingKeysWith: { first, _ in first })
		// Engine-reserved directories (the guest setup payload and its report drop-box).
		// Mount validation refuses their names, so the merge cannot shadow a user mount.
		sharedDirectories.merge(extraDirectories) { _, extra in extra }
		let multipleDirectoryShare = VZMultipleDirectoryShare(directories: sharedDirectories)
		let sharingConfiguration = VZVirtioFileSystemDeviceConfiguration(tag: mainTag)
		sharingConfiguration.share = multipleDirectoryShare

		return sharingConfiguration
	}
}
