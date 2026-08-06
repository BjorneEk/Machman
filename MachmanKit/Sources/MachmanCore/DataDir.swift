//
//  DataDir.swift
//  MachmanCore
//
//  The engine's view of the data dir. Resolution itself lives in MachmanAPI (MachmanPaths) so
//  clients can find the daemon's socket without linking the engine; this file pins the resolved
//  value into the mutable global the engine uses (tests swap it via VMTestSupport) and enforces
//  the dev guard.
//

import Foundation
import AppKit
import MachmanAPI

var machmanVMDir: String = {
	let dir = MachmanPaths.dataDir()
	enforceDevDataDirGuard(resolved: dir)
	return dir
}()

// The daemon's socket, derived from the LIVE global so redirected test dirs get their own.
func machmanSocketPath() -> String {
	MachmanPaths.socketPath(dataDir: machmanVMDir)
}

// TODO(cutover): remove this guard when Machmand takes over ~/.machman as the production
// daemon. Until then, refactor-branch builds must never operate on the production data dir —
// the original Machman.app is in active use on it.
func enforceDevDataDirGuard(resolved: String) {
	// The test host redirects the dir per-test (VMTestSupport); don't block test runs.
	if NSClassFromString("XCTestCase") != nil {
		return
	}
	let production = URL(fileURLWithPath: NSHomeDirectory() + "/.machman").standardizedFileURL
	guard URL(fileURLWithPath: resolved).standardizedFileURL == production else {
		return
	}
	let msg = "This development build refuses to use the production data dir "
		+ "\(production.path). Run scripts/dev-setup.sh once, or set MACHMAN_DATA_DIR / "
		+ "the MachmanDataDir user default to a dev directory."
	FileHandle.standardError.write(Data(("machman: " + msg + "\n").utf8))
	let alert = NSAlert()
	alert.messageText = "Machman dev build blocked"
	alert.informativeText = msg
	alert.alertStyle = .critical
	alert.runModal()
	exit(1)
}
