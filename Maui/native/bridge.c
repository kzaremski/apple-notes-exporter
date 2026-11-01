#define _GNU_SOURCE
#include "bridge.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>
#include "utils.h"
#include "client.h"
#include "conf.h"
#include "device.h"
#include "usb.h"

int notes_usb_fd = -1;
int no_preflight = 1;
int use_logfile = 0;
static pthread_mutex_t transfer_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool cancelled;
static atomic_bool mux_stopped;
static notes_progress progress;
static int listener = -1;

void notes_report(const char *message)
{
    if (progress)
        progress(message);
}

int notes_printf(const char *format, ...)
{
    char message[1024];
    va_list arguments;
    va_start(arguments, format);
    int result = vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    notes_report(message);
    return result;
}

int notes_fprintf(FILE *stream, const char *format, ...)
{
    (void)stream;
    char message[1024];
    va_list arguments;
    va_start(arguments, format);
    int result = vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    notes_report(message);
    return result;
}

static void *mux_loop(void *unused)
{
    (void)unused;
    struct fdlist descriptors;
    fdlist_create(&descriptors);
    while (!atomic_load(&mux_stopped) && !atomic_load(&cancelled)) {
        fdlist_reset(&descriptors);
        fdlist_add(&descriptors, FD_LISTEN, listener, POLLIN);
        usb_get_fds(&descriptors);
        client_get_fds(&descriptors);
        int timeout = usb_get_timeout();
        int device_timeout = device_get_timeout();
        if (device_timeout < timeout)
            timeout = device_timeout;
        if (timeout > 50)
            timeout = 50;
        int ready = poll(descriptors.fds, descriptors.count, timeout);
        if (ready < 0 && errno != EINTR) {
            notes_report("USB event processing failed.");
            break;
        }
        for (int i = 0; i < descriptors.count; ++i) {
            if (!descriptors.fds[i].revents)
                continue;
            if (descriptors.owners[i] == FD_LISTEN)
                client_accept(listener);
            else if (descriptors.owners[i] == FD_CLIENT)
                client_process(descriptors.fds[i].fd, descriptors.fds[i].revents);
        }
        if (usb_process() < 0) {
            notes_report("USB connection lost. Reconnect the cable and try again.");
            break;
        }
        device_check_timeouts();
    }
    fdlist_free(&descriptors);
    device_kill_connections();
    usb_shutdown();
    device_shutdown();
    client_shutdown();
    return NULL;
}

__attribute__((visibility("default")))
void notes_cancel(void)
{
    atomic_store(&cancelled, true);
    notes_backup_cancel();
}

__attribute__((visibility("default")))
int notes_transfer(int usb_fd, const char *private_directory, const char *backup_directory,
                   notes_progress callback)
{
    if (pthread_mutex_trylock(&transfer_lock) != 0)
        return -1;
    progress = callback;
    int result = -1;
    bool thread_started = false;
    bool clients_initialized = false;
    bool usb_initialized = false;
    pthread_t thread;
    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    char pairing_path[4096];
    char socket_address[sizeof(socket_path) + 6];
    idevice_t device = NULL;
    lockdownd_client_t lockdown = NULL;
    char *udid = NULL;
    sigset_t blocked, previous;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    atomic_store(&mux_stopped, false);

    if (!private_directory || !backup_directory || usb_fd < 0 || atomic_load(&cancelled))
        goto cleanup;
    if (snprintf(socket_path, sizeof(socket_path), "%s/mux.sock", private_directory) >= (int)sizeof(socket_path) ||
        snprintf(pairing_path, sizeof(pairing_path), "%s/pairing", private_directory) >= (int)sizeof(pairing_path)) {
        notes_report("The app's private storage path is too long.");
        goto cleanup;
    }
    mkdir(pairing_path, 0700);
    if (config_set_config_dir(pairing_path) < 0) {
        notes_report("Could not create private iPhone pairing storage.");
        goto cleanup;
    }
    chmod(pairing_path, 0700);
    snprintf(socket_address, sizeof(socket_address), "UNIX:%s", socket_path);
    setenv("USBMUXD_SOCKET_ADDRESS", socket_address, 1);
    // A mode switch re-enumerates USB and invalidates Android's authorized descriptor.
    setenv("USBMUXD_DEFAULT_DEVICE_MODE", "0", 1);
    notes_usb_fd = dup(usb_fd);
    if (notes_usb_fd < 0)
        goto cleanup;
    listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strncpy(address.sun_path, socket_path, sizeof(address.sun_path) - 1);
    unlink(socket_path);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        chmod(socket_path, 0600) < 0 || listen(listener, 16) < 0) {
        notes_report("Could not create the private USB protocol socket.");
        goto cleanup;
    }
    client_init();
    device_init();
    clients_initialized = true;
    notes_report("Opening the iPhone's USB interface...");
    if (usb_init() < 0) {
        notes_report("Cannot claim the iPhone USB interface. Reconnect with Android controlling USB.");
        goto cleanup;
    }
    usb_initialized = true;
    if (pthread_create(&thread, NULL, mux_loop, NULL) != 0)
        goto cleanup;
    thread_started = true;

    for (int attempt = 0; attempt < 150 && !atomic_load(&cancelled); ++attempt) {
        if (idevice_new_with_options(&device, NULL, IDEVICE_LOOKUP_USBMUX) == IDEVICE_E_SUCCESS)
            break;
        usleep(100000);
    }
    if (!device) {
        notes_report("No iPhone backup interface appeared. Check the cable, USB host mode, and iPhone unlock state.");
        goto cleanup;
    }
    idevice_get_udid(device, &udid);
    notes_report("Unlock the iPhone, accept Trust, and enter its passcode.");
    lockdownd_error_t error = LOCKDOWN_E_UNKNOWN_ERROR;
    for (int attempt = 0; attempt < 120 && !atomic_load(&cancelled); ++attempt) {
        error = lockdownd_client_new_with_handshake(device, &lockdown, "Notes Cable Transfer");
        if (error == LOCKDOWN_E_SUCCESS)
            break;
        if (lockdown) {
            lockdownd_client_free(lockdown);
            lockdown = NULL;
        }
        if (error != LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING && error != LOCKDOWN_E_PASSWORD_PROTECTED)
            break;
        sleep(1);
    }
    if (error != LOCKDOWN_E_SUCCESS || !lockdown) {
        notes_printf("iPhone pairing failed: %s. Unlock the iPhone and accept Trust, then retry.", lockdownd_strerror(error));
        goto cleanup;
    }
    plist_t encryption = NULL;
    error = lockdownd_get_value(lockdown, "com.apple.mobile.backup", "WillEncrypt", &encryption);
    if (error != LOCKDOWN_E_SUCCESS || !encryption || plist_get_node_type(encryption) != PLIST_BOOLEAN) {
        plist_free(encryption);
        notes_report("Could not determine whether the iPhone backup is encrypted. No backup was started.");
        goto cleanup;
    }
    uint8_t encrypted = 0;
    plist_get_bool_val(encryption, &encrypted);
    plist_free(encryption);
    if (encrypted) {
        notes_report("This iPhone requires an encrypted backup. Decryption is not implemented; encryption settings were not changed.");
        result = -2;
        goto cleanup;
    }
    lockdownd_client_free(lockdown);
    lockdown = NULL;
    if (atomic_load(&cancelled))
        goto cleanup;
    notes_report("Creating the local iPhone backup. Keep both phones connected and respond to iPhone prompts.");
    result = notes_backup_run(udid, backup_directory);

cleanup:
    if (lockdown)
        lockdownd_client_free(lockdown);
    if (device)
        idevice_free(device);
    free(udid);
    atomic_store(&mux_stopped, true);
    if (thread_started)
        pthread_join(thread, NULL);
    else if (clients_initialized) {
        if (usb_initialized)
            usb_shutdown();
        device_shutdown();
        client_shutdown();
    }
    if (listener >= 0)
        close(listener);
    listener = -1;
    if (notes_usb_fd >= 0)
        close(notes_usb_fd);
    notes_usb_fd = -1;
    if (socket_path[0])
        unlink(socket_path);
    progress = NULL;
    atomic_store(&cancelled, false);
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    pthread_mutex_unlock(&transfer_lock);
    return result;
}
