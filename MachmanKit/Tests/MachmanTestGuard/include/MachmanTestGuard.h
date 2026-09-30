// MachmanTestGuard has no API: linking it into a test target is the whole point. Its load-time
// constructor (guard.c) refuses to let a test process start outside a per-run sandbox.
#pragma once
