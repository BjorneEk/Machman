//
//  guard.c
//  MachmanTestGuard
//
//  Runs at image load, before Swift Testing discovers a single test and before any lazily
//  initialized path global (machmanVMDir, machmanRuntimeDir, ...) can be read. A test process
//  outside a per-run sandbox would resolve the .dev or the RELEASE suite — the production
//  library and daemon socket dir — so it exits loudly instead. The contract, exported by
//  scripts/test.sh and never by hand:
//
//    MACHMAN_SUITE_ID   com.gustaffranzen.Machman.test-<token>   token = 3-32 alphanumerics
//    MACHMAN_DATA_DIR   an absolute path containing <token>      library + safe-run root
//    CFFIXED_USER_HOME  an absolute path containing <token>      NSHomeDirectory() et al.
//
//  TestEnvironment.swift re-checks this contract as a backstop; keep the two in step.
//
//  stderr, not MachmanLogger: this runs before Swift does, and in test tooling only.
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SUITE_PREFIX "com.gustaffranzen.Machman.test-"

static void refuse(const char *why) {
	fprintf(stderr, "MachmanTestGuard: refusing to run tests: %s\n", why);
	fprintf(stderr, "  Run the suite through scripts/test.sh: it exports a per-run\n");
	fprintf(stderr, "  MACHMAN_SUITE_ID (" SUITE_PREFIX "<token>), MACHMAN_DATA_DIR and\n");
	fprintf(stderr, "  CFFIXED_USER_HOME under that token, and removes them afterwards.\n");
	fprintf(stderr, "  Without them the tests resolve the real .dev or Release paths.\n");
	_exit(78);
}

static int token_is_valid(const char *token) {
	size_t length = strlen(token);
	if (length < 3 || length > 32) {
		return 0;
	}
	for (size_t i = 0; i < length; i++) {
		char c = token[i];
		int alphanumeric =
			(c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
		if (!alphanumeric) {
			return 0;
		}
	}
	return 1;
}

static void require_path_with_token(const char *name, const char *token) {
	const char *value = getenv(name);
	if (value == NULL || value[0] != '/' || strstr(value, token) == NULL) {
		char why[512];
		snprintf(why, sizeof why, "%s must be an absolute path containing the run token "
			"'%s' (got '%s')", name, token, value ? value : "(unset)");
		refuse(why);
	}
}

__attribute__((constructor))
static void machman_test_guard(void) {
	const char *suite = getenv("MACHMAN_SUITE_ID");
	if (suite == NULL || suite[0] == '\0') {
		refuse("MACHMAN_SUITE_ID is unset (it would fall back to the Release suite)");
	}
	if (strncmp(suite, SUITE_PREFIX, strlen(SUITE_PREFIX)) != 0) {
		char why[512];
		snprintf(why, sizeof why, "MACHMAN_SUITE_ID '%s' is not a per-run test suite id", suite);
		refuse(why);
	}
	const char *token = suite + strlen(SUITE_PREFIX);
	if (!token_is_valid(token)) {
		refuse("the MACHMAN_SUITE_ID token must be 3-32 alphanumerics");
	}
	require_path_with_token("MACHMAN_DATA_DIR", token);
	require_path_with_token("CFFIXED_USER_HOME", token);
}
