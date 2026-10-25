/* Logging for libmcmetal. Set MGL_LOG=/path/file to log to a file (default: stderr). */
#pragma once
void mgl_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void mgl_unimplemented(const char *name);
/* prints the calling Java thread's stack to System.err (Thread.dumpStack), if this thread runs Java code */
void mgl_java_stack(void);
