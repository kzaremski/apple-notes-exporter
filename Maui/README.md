# Android USB Notes transfer (experimental)

This is an Android .NET MAUI app for a **direct USB cable connection to an
iPhone**. No Mac, PC, iCloud login, root access, shell executable, or
manually created backup is part of the transfer flow.

The app is not yet validated against connected phones. An APK build or passing
offline checks does **not** prove hardware compatibility.

## What it does

1. Requests Android USB-host access to the attached Apple device.
2. Passes the authorized `UsbDeviceConnection` descriptor to
   `libusb_wrap_sys_device`. It does not try to open privileged USB device nodes.
3. Runs usbmuxd's USB/client event processing in the app, using a private Unix
   socket rather than a system daemon or network listener.
4. Uses libimobiledevice for iPhone Trust pairing, TLS, and MobileBackup2.
5. Creates a backup in Android app-private storage, extracts the Notes group
   container, and decodes the text using the existing `notestore.proto` layout.
6. Keeps the Notes files/attachments and `notes.json`, removes the full backup
   after successful extraction, and lets you save/share a ZIP.

This is a new Android acquisition client, **not** a C# rewrite of all 18 Swift
export formats. It does not run the macOS CLI on Android.

## Requirements and limitations

- ARM64 Android 8 or later, USB host/OTG support, and sufficient free storage for
  an iPhone backup. A USB-C/Lightning data cable may need an OTG adapter at the
  Android end. Charging-only cables do not work.
- Android must be the USB host. With USB-C phones, check Android's USB controls
  if it instead offers file transfer to the iPhone.
- Unlock the iPhone, accept **Trust**, and respond to passcode prompts. Trust
  rejection, a locked phone, or iOS USB restrictions can block transfer.
- Only data that iOS includes in its backup can be retrieved. Cloud-only data,
  enterprise policy restrictions, and unsupported iOS schema changes can limit
  the result.
- Encrypted device backups are detected and rejected before starting a backup.
  The app never turns encryption off. Password-based backup decryption and
  locked-note decryption are not implemented.
- Text is decoded; original attachment files and the Notes database are
  preserved in the ZIP. Rich-text rendering, attachment placement, and legacy
  pre-iCloud Notes schemas are not implemented. Individual undecodable notes
  are reported, not silently counted as successfully decoded.
- A foreground service keeps transfers running when the activity is backgrounded.
  Force-stopping the app or disconnecting the cable interrupts the transfer.

## Privacy

The backup protocol may transfer data beyond Notes. The app asks for consent
before starting. All backup and pairing data lives in app-private storage;
Android app backup is disabled. The app requests no Internet permission.
Successful extraction deletes the temporary full backup. On failure it is
retained for diagnosis/retry until **Delete local transfer and pairing** is used.
The same action deletes extracted notes, the shared ZIP, and pairing keys.
Uninstalling also removes private data. Sharing a ZIP intentionally sends those
Notes files to the destination you choose.

## Build a sideload APK

Build on Linux with .NET 10, JDK 21, the Android SDK (platform/build tools 36),
Android NDK r27 or later, Git, Python 3, Perl, Make, Autoconf, Automake,
Libtool, and pkg-config:

```sh
dotnet workload install maui-android
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"
export JAVA_HOME=/path/to/jdk-21
bash Maui/native/build.sh android
dotnet publish Maui/AppleNotes.Android/AppleNotes.Android.csproj -c Release \
  -p:AndroidKeyStore=false -p:AndroidSdkDirectory="$ANDROID_HOME" \
  -p:JavaSdkDirectory="$JAVA_HOME"
```

The `*-Signed.apk` under
`Maui/AppleNotes.Android/bin/Release/net10.0-android/android-arm64/publish/`
is signed with the SDK's local debug key for sideload testing, not a production
release key. Download/open it on Android and allow installation from the browser
or file manager when prompted. A future APK built with a different key requires
uninstalling the previous build (which deletes its private data).

The **Android USB APK** GitHub Actions workflow runs the same build and uploads
`NotesCableTransfer-arm64.apk` and its SHA-256 checksum as a workflow artifact.
Forks must enable Actions before workflows can run.

## Offline validation

```sh
dotnet run --project Maui/AppleNotes.Core.Tests -c Release
# Optional Linux link check (requires libusb, OpenSSL, curl and udev development packages):
bash Maui/native/build.sh host
```

For real-device acceptance, test permission denial, Trust denial/acceptance,
first/subsequent pairing, cable removal, cancellation, app backgrounding,
encrypted-backup rejection, notes containing Unicode and attachments, sharing,
and deletion. Confirm exported note text against the source iPhone.

## Native dependencies and licensing

The native build downloads pinned source revisions of libusb (LGPL),
usbmuxd (GPL), libusbmuxd, libimobiledevice, libimobiledevice-glue, libplist,
libtatsu (LGPL), OpenSSL (Apache-2.0), and curl (curl license). Their upstream
license files are collected into the APK assets. See the pinned repositories in
`native/build.sh` and each upstream license for full terms. Changes to the
upstream sources are reproducible through `native/patch_sources.py`; no
precompiled third-party binary is checked in. The port follows this
repository's GPLv3 license.
