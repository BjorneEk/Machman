// MachmanPTYSpawn — starts a process on a pty that is its CONTROLLING terminal (PTYChild.swift).
// C because the child runs code between fork and exec, where no Swift may run.
#pragma once

#include <sys/types.h>

// Starts `path` (argv, envp: NULL-terminated, argv[0] included) as the leader of a new session
// whose controlling terminal is the pty slave `slave`, which becomes its stdin, stdout and
// stderr. No other descriptor of the caller reaches the program, every signal starts at its
// default and none is blocked. Returns the child's pid once it runs the program, or -1 with
// errno set when it could not start; a child that failed is reaped here, a running one is
// the caller's to reap.
pid_t machman_pty_spawn(const char *path, char *const argv[], char *const envp[], int slave);
