#pragma once

#include <stdio.h>

typedef void (*notes_progress)(const char *message);
void notes_report(const char *message);
int notes_printf(const char *format, ...);
int notes_fprintf(FILE *stream, const char *format, ...);
int notes_backup_run(const char *udid, const char *directory);
void notes_backup_cancel(void);
