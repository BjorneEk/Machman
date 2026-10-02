//
//  UnavailableGateTests.swift
//  MachmanUITests
//
//  H15: every device gate was headed "Unavailable on this host", so a trackpad on an EFI
//  guest blamed a host that is fine. The header now comes from the gate's reason.
//

import Testing
import MachmanAPI
import MachmanUI

struct UnavailableGateTests {
	private func headline(_ reason: UnavailabilityInfo.Reason) -> String {
		UnavailabilityInfo(reason: reason, message: "m").headline
	}

	@Test func aGuestTypeLimitIsTheVMsNotTheHosts() {
		#expect(headline(.unsupportedHost) == "Not available for this VM")
	}

	@Test func hostLimitsNameTheHost() {
		#expect(headline(.privateUARTGated) == "Unavailable on this host")
		#expect(headline(.classUnavailable) == "Unavailable on this host")
		#expect(headline(.notInstalled) == "Unavailable on this host")
	}

	@Test func anUnknownReasonClaimsNeither() {
		#expect(headline(.unknown) == "Unavailable")
	}
}
