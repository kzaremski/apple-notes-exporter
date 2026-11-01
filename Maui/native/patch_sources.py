#!/usr/bin/env python3
"""Adapt pinned upstream sources to an in-process, authorized Android USB FD."""

import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Upstream patch anchor changed: {old[:100]!r}")
    return text.replace(old, new, 1)


usb = root / "usbmuxd/src/usb.c"
text = usb.read_text()
text = replace_once(
    text,
    '#include "usb.h"',
    '#include "usb.h"\n#undef HAVE_LIBUSB_HOTPLUG_API\n'
    "extern int notes_usb_fd;\nstatic libusb_device_handle *authorized_handle;\n",
)
text = replace_once(
    text,
    "if((res = libusb_open(dev, &handle)) != 0)",
    "if((handle = authorized_handle) == NULL)",
)
start = text.index("int usb_init(void)")
end = text.index("\nvoid usb_shutdown(void)", start)
text = text[:start] + """
int usb_init(void)
{
    devlist_failures = 0;
    device_polling = 0;
    device_hotplug = 0;
    libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
    if (libusb_init(NULL) != 0)
        return -1;
    collection_init(&device_list);
    int result = libusb_wrap_sys_device(NULL, notes_usb_fd, &authorized_handle);
    if (result != 0) {
        collection_free(&device_list);
        libusb_exit(NULL);
        return -1;
    }
    result = usb_device_add(libusb_get_device(authorized_handle));
    if (result < 0) {
        if (collection_count(&device_list) == 0)
            libusb_close(authorized_handle);
        usb_shutdown();
    }
    return result;
}
""" + text[end:]
usb.write_text(text)

tool = root / "libimobiledevice/tools/idevicebackup2.c"
text = tool.read_text()
text = replace_once(
    text,
    "#define LOCK_ATTEMPTS 50",
    '#include "bridge.h"\n#include <stdatomic.h>\n'
    "#define printf notes_printf\n#define fprintf notes_fprintf\n"
    "#define LOCK_ATTEMPTS 50",
)
text = replace_once(text, "static int quit_flag = 0;", "static _Atomic int quit_flag = 0;")
text = replace_once(text, "int main(int argc, char *argv[])", "static int backup_main(int argc, char *argv[])")
for line in ["signal(SIGINT, clean_exit);", "signal(SIGTERM, clean_exit);",
             "signal(SIGQUIT, clean_exit);", "signal(SIGPIPE, SIG_IGN);"]:
    text = replace_once(text, line, "/* Signals belong to the Android runtime, not this embedded tool. */")
text += """
int notes_backup_run(const char *udid, const char *directory)
{
    quit_flag = 0;
    backup_domain_changed = 0;
    overall_progress = 0;
    verbose = 1;
    optind = 0;
    char *arguments[] = {"notes-backup", "-u", (char *)udid, "--full",
                         "backup", (char *)directory, NULL};
    return backup_main(6, arguments);
}

void notes_backup_cancel(void)
{
    quit_flag = 1;
}
"""
tool.write_text(text)

# Bionic implements pthread functions in libc; there is no separate libpthread.
if sys.argv[2] == "android":
    for package in ["libimobiledevice", "glue"]:
        configure = root / package / "configure.ac"
        text = configure.read_text()
        text = replace_once(
            text,
            "AC_CHECK_LIB(pthread, [pthread_once], [], [AC_MSG_ERROR([pthread with pthread_once required to build $PACKAGE_NAME])])",
            "AC_CHECK_FUNCS([pthread_once])",
        )
        configure.write_text(text)
