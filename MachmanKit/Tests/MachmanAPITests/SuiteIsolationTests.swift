//
//  SuiteIsolationTests.swift
//  MachmanAPITests
//
//  The in-process half of the test sandbox (MachmanTestGuard is the load-time half): every
//  path the engine derives resolves inside this run's suite — never the .dev or Release one.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport

struct SuiteIsolationTests {
	@Test func suiteIdentifierIsThePerRunTestSuite() {
		let suite = MachmanPaths.suiteIdentifier()
		#expect(suite == TestEnvironment.suiteID)
		#expect(suite.hasPrefix(TestEnvironment.suitePrefix))
		#expect(suite != "com.gustaffranzen.Machman")
		#expect(!suite.hasSuffix(".dev"))
	}

	// The expressions MachmanCore's DataDir.swift initializes machmanVMDir, machmanSafeDir and
	// machmanRuntimeDir from. (The globals themselves are swapped by VMTestDir under a lock;
	// VMTestDir asserts their pre-swap values, which is the read that matters.)
	@Test func engineDirectoriesResolveInsideTheRun() {
		#expect(MachmanPaths.vmsDir() == TestEnvironment.dataDir + "/VMs")
		#expect(MachmanPaths.safeRunsDir(dataDir: MachmanPaths.dataDir())
			== TestEnvironment.dataDir + "/safe")
		#expect(MachmanPaths.runtimeDir().hasSuffix("/" + TestEnvironment.suiteID))
		#expect(MachmanPaths.daemonSocketPath().contains(TestEnvironment.token))
		#expect(MachmanPaths.vmSocketPath(vm: "x").contains(TestEnvironment.token))
	}

	@Test func homeRelativePathsLandInTheFakeHome() {
		#expect(NSHomeDirectory() == TestEnvironment.homeDir)
		#expect(FileManager.default.homeDirectoryForCurrentUser.path == TestEnvironment.homeDir)
		#expect(MachmanPaths.defaultDataDir().hasPrefix(TestEnvironment.homeDir))
	}

	@Test func scratchIsInsideTheRunAndShortEnoughForSockets() {
		#expect(TestEnvironment.scratch.hasPrefix(TestEnvironment.dataDir))
		#expect(TestEnvironment.scratch.hasSuffix("/"))
		// A typical socket name under it must stay inside sun_path (104 bytes).
		#expect((TestEnvironment.scratch + "mm-unadopted-99999-99999.sock").utf8.count < 104)
	}
}
