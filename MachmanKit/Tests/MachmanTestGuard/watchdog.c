//
//  watchdog.c
//  MachmanTestGuard
//
//  An opt-in measurement, never a check (Q43): with MM_WATCHDOG=1 in the environment of
//  scripts/test.sh, a thread of its own pings the main queue every 50 ms. A ping still
//  unanswered after 300 ms has the main thread sampled — suspended, its frame chain walked,
//  each frame named by dladdr — once at 300 ms and again every 400 ms the stall lasts, and the
//  stall's length is printed once the ping lands. Lines go to stderr as
//
//    PROBE sample HH:MM:SS.mmm main stalled <ms> ms:
//    PROBE   #<i> <symbol>
//    PROBE stall HH:MM:SS.mmm <ms> ms
//
//  and scripts/test-watchdog/attribute.py names the test each sample was in. Without the
//  variable the constructor returns at once: nothing runs, nothing prints. Frames are walked on
//  arm64 only; elsewhere the stalls are timed but not sampled.
//
//  stderr, not MachmanLogger: test tooling, like guard.c.
//

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static _Atomic int wd_pending;
static _Atomic mach_port_t wd_main_port;
static void *wd_stack_top;
static void *wd_stack_bottom;

static uint64_t wd_now_ms(void) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

static void wd_stamp(char *buffer, size_t size) {
	struct timeval now;
	gettimeofday(&now, NULL);
	struct tm local;
	localtime_r(&now.tv_sec, &local);
	snprintf(buffer, size, "%02d:%02d:%02d.%03d", local.tm_hour, local.tm_min, local.tm_sec,
		(int)(now.tv_usec / 1000));
}

// On the main thread: what the sampler needs to find and bound its stack.
static void wd_capture(void *unused) {
	(void)unused;
	pthread_t main_thread = pthread_self();
	wd_stack_top = pthread_get_stackaddr_np(main_thread);
	wd_stack_bottom = (char *)wd_stack_top - pthread_get_stacksize_np(main_thread);
	atomic_store(&wd_main_port, pthread_mach_thread_np(main_thread));
}

static void wd_pong(void *unused) {
	(void)unused;
	atomic_store(&wd_pending, 0);
}

static void wd_name(int index, uintptr_t pc) {
	Dl_info info;
	if (dladdr((void *)pc, &info) != 0 && info.dli_sname != NULL) {
		fprintf(stderr, "PROBE   #%d %s\n", index, info.dli_sname);
	} else {
		fprintf(stderr, "PROBE   #%d 0x%lx\n", index, (unsigned long)pc);
	}
}

#if defined(__arm64__)
// A return address without its pointer-authentication bits.
static uintptr_t wd_strip(uintptr_t address) {
	return address & 0x0000000FFFFFFFFFULL;
}

// The main thread's frames, read while it is suspended: pc, lr, then the frame-pointer chain,
// bounded by its stack.
static int wd_frames(mach_port_t port, uintptr_t *frames, int capacity) {
	int count = 0;
	arm_thread_state64_t state;
	mach_msg_type_number_t size = ARM_THREAD_STATE64_COUNT;
	if (thread_get_state(port, ARM_THREAD_STATE64, (thread_state_t)&state, &size)
		!= KERN_SUCCESS) {
		return 0;
	}
	frames[count++] = wd_strip((uintptr_t)arm_thread_state64_get_pc(state));
	frames[count++] = wd_strip((uintptr_t)arm_thread_state64_get_lr(state));
	uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
	while (count < capacity && fp != 0 && (fp & 0x7) == 0 && (void *)fp >= wd_stack_bottom
		&& (void *)(fp + 16) <= wd_stack_top) {
		uintptr_t next = ((uintptr_t *)fp)[0];
		uintptr_t ret = wd_strip(((uintptr_t *)fp)[1]);
		if (ret == 0) break;
		frames[count++] = ret;
		if (next <= fp) break;
		fp = next;
	}
	return count;
}
#else
static int wd_frames(mach_port_t port, uintptr_t *frames, int capacity) {
	(void)port;
	(void)frames;
	(void)capacity;
	return 0;
}
#endif

static void wd_sample(uint64_t stalled) {
	mach_port_t port = atomic_load(&wd_main_port);
	if (port == MACH_PORT_NULL || thread_suspend(port) != KERN_SUCCESS) return;
	uintptr_t frames[40];
	int count = wd_frames(port, frames, 40);
	thread_resume(port);
	// Printed after the resume: stdio may take a lock the main thread held.
	char stamp[32];
	wd_stamp(stamp, sizeof stamp);
	fprintf(stderr, "PROBE sample %s main stalled %llu ms:\n", stamp,
		(unsigned long long)stalled);
	for (int i = 0; i < count; i++) wd_name(i, frames[i]);
}

static void *wd_run(void *unused) {
	(void)unused;
	dispatch_async_f(dispatch_get_main_queue(), NULL, wd_capture);
	while (atomic_load(&wd_main_port) == MACH_PORT_NULL) usleep(10000);
	for (;;) {
		atomic_store(&wd_pending, 1);
		uint64_t sent = wd_now_ms();
		dispatch_async_f(dispatch_get_main_queue(), NULL, wd_pong);
		uint64_t next_sample = 300;
		while (atomic_load(&wd_pending)) {
			usleep(10000);
			uint64_t waited = wd_now_ms() - sent;
			if (waited >= next_sample) {
				wd_sample(waited);
				next_sample += 400;
			}
		}
		uint64_t waited = wd_now_ms() - sent;
		if (waited >= 300) {
			char stamp[32];
			wd_stamp(stamp, sizeof stamp);
			fprintf(stderr, "PROBE stall %s %llu ms\n", stamp, (unsigned long long)waited);
		}
		usleep(50000);
	}
	return NULL;
}

__attribute__((constructor))
static void wd_start(void) {
	const char *on = getenv("MM_WATCHDOG");
	if (on == NULL || strcmp(on, "1") != 0) return;
	pthread_t thread;
	if (pthread_create(&thread, NULL, wd_run, NULL) == 0) pthread_detach(thread);
}
