//
//  pty_spawn.c
//  MachmanPTYSpawn
//
//  A pty becomes a process's controlling terminal only when a session leader without one
//  opens it or asks for it (TIOCSCTTY). posix_spawn can't do either: it runs its file actions
//  before POSIX_SPAWN_SETSID, so the child it starts opens the slave as no leader and then
//  leaves that session — no controlling terminal, so no /dev/tty for ssh's password prompt,
//  no SIGHUP when the master closes, no SIGWINCH on a resize (P42).
//
//  So the child is forked: it makes its own session, takes the slave as its terminal, and
//  then lets posix_spawn with POSIX_SPAWN_SETEXEC run the program in place. That exec does
//  what the old spawn did — the kernel closes every descriptor but 0, 1 and 2
//  (POSIX_SPAWN_CLOEXEC_DEFAULT) and resets every signal — atomically, with no loop over the
//  descriptor table. A failed exec reports its errno through a close-on-exec pipe, which
//  reads as end-of-file once the program runs.
//
//  The parent is multithreaded, so its fork copies one thread into a process whose locks
//  (malloc's included) other threads may have held. The child therefore calls only these,
//  none of which takes a lock or allocates:
//    setsid, ioctl, fcntl, write, _exit  system calls, async-signal-safe (POSIX, or a bare
//                                        trap: ioctl);
//    posix_spawn                         given objects built BEFORE the fork, Darwin's
//                                        wrapper fills a descriptor on its own stack and
//                                        traps (__posix_spawn); it allocates nothing.
//  launchd starts its jobs the same way (fork, setsid, posix_spawn with SETEXEC).
//

#include "MachmanPTYSpawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

// The child's half: never returns. Only the calls named above.
static void become_session_on(int slave, int report, const char *path, char *const argv[],
	char *const envp[], const posix_spawn_file_actions_t *actions,
	const posix_spawnattr_t *attributes) {
	int error = 0;
	// The slave is close-on-exec (so no other spawn of the app inherits it), and an exec
	// in place refuses such a descriptor as a dup2 source (measured: EBADF). The exec
	// still closes the slave's own number: no file action keeps it.
	if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || fcntl(slave, F_SETFD, 0) < 0) {
		error = errno;
	} else {
		pid_t self;
		error = posix_spawn(&self, path, actions, attributes, argv, envp);
	}
	(void)write(report, &error, sizeof error);
	_exit(127);
}

// The exec in place: the slave on 0, 1 and 2, every other descriptor closed, every signal
// at its default and none blocked. 0, or the errno of the first call that failed — a
// spawn missing any of these must not run.
static int describe_exec(int slave, posix_spawn_file_actions_t *actions,
	posix_spawnattr_t *attributes) {
	int error = 0;
	for (int fd = 0; fd <= 2 && error == 0; fd++) {
		error = posix_spawn_file_actions_adddup2(actions, slave, fd);
	}
	sigset_t all, none;
	sigfillset(&all);
	sigemptyset(&none);
	if (error == 0) {
		error = posix_spawnattr_setsigdefault(attributes, &all);
	}
	if (error == 0) {
		error = posix_spawnattr_setsigmask(attributes, &none);
	}
	if (error == 0) {
		error = posix_spawnattr_setflags(attributes, POSIX_SPAWN_SETEXEC
			| POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
	}
	return error;
}

// Forks the child and waits for its exec: its pid, or -1 with *error set (the child reaped).
static pid_t start_child(int slave, const char *path, char *const argv[], char *const envp[],
	const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes,
	int *error) {
	int report[2];
	if (pipe(report) != 0) {
		*error = errno;
		return -1;
	}
	(void)fcntl(report[0], F_SETFD, FD_CLOEXEC);
	(void)fcntl(report[1], F_SETFD, FD_CLOEXEC);
	pid_t pid = fork();
	if (pid == 0) {
		become_session_on(slave, report[1], path, argv, envp, actions, attributes);
	}
	if (pid < 0) {
		*error = errno;
	}
	close(report[1]);
	if (pid > 0) {
		// Nothing to read: the program runs. An errno: the child gave up and exits. A pipe
		// that can't be read leaves the child's fate unknown, so it is ended: the caller
		// gets no process it can't track.
		int failed = 0;
		ssize_t got;
		do {
			got = read(report[0], &failed, sizeof failed);
		} while (got < 0 && errno == EINTR);
		if (got != 0) {
			if (got < 0) {
				*error = errno;
				(void)kill(pid, SIGKILL);
			} else {
				*error = failed;
			}
			while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
			pid = -1;
		}
	}
	close(report[0]);
	return pid;
}

pid_t machman_pty_spawn(const char *path, char *const argv[], char *const envp[], int slave) {
	posix_spawn_file_actions_t actions;
	posix_spawnattr_t attributes;
	int error = posix_spawn_file_actions_init(&actions);
	if (error != 0) {
		errno = error;
		return -1;
	}
	error = posix_spawnattr_init(&attributes);
	if (error != 0) {
		posix_spawn_file_actions_destroy(&actions);
		errno = error;
		return -1;
	}
	pid_t pid = -1;
	error = describe_exec(slave, &actions, &attributes);
	if (error == 0) {
		pid = start_child(slave, path, argv, envp, &actions, &attributes, &error);
	}
	posix_spawn_file_actions_destroy(&actions);
	posix_spawnattr_destroy(&attributes);
	if (pid < 0) {
		errno = error;
	}
	return pid;
}
