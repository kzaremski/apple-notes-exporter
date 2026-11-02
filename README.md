# Notes Cable Transfer

An experimental Android app for transferring Apple Notes directly from an
iPhone to an Android phone over USB. It is designed to complement Samsung
Smart Switch: use Smart Switch for the data it migrates, then use Notes Cable
Transfer for the Apple Notes that do not come across.

The app is built with .NET MAUI and runs the iPhone backup and Notes extraction
on the Android phone. It is independent of Samsung and is not affiliated with
or endorsed by Samsung or Apple.

> **Experimental:** the app has not yet been validated with connected iPhones.
> A successful build or offline test does not guarantee that a particular
> phone, cable, or iOS version will work.

## What it does

- Connects an iPhone directly to an Android phone acting as the USB host.
- Uses Apple's device-backup protocol to retrieve the Notes data available in
  the iPhone backup.
- Keeps the extracted note text, Notes data, and attachments, then lets you
  save or share them as a ZIP file.
- Works on the Android phone without a Mac, PC, iCloud sign-in, or root access.

This is an Android acquisition app, not a port of the macOS exporter's
format-conversion tools. It does not provide the macOS app's CLI, Shortcuts,
MCP server, or export formats.

## Requirements

- ARM64 Android 8 or later with USB host / OTG support.
- A data-capable USB cable and, if needed, an OTG adapter. The Android phone
  must be the USB host.
- An unlocked iPhone. Accept its **Trust** prompt and enter its passcode when
  asked.
- Enough free space for a temporary iPhone backup, which can be much larger
  than the Notes data itself.

Charging-only cables do not work. Some Android phones may default to acting as
a USB device instead of the host.

## Transfer notes

1. Install and open **Notes Cable Transfer** on Android.
2. Connect the unlocked iPhone to Android with a data-capable cable.
3. Tap **Transfer from iPhone** and review the local-backup consent prompt.
4. Accept **Trust** on the iPhone and respond to any passcode prompt.
5. When the notes appear, tap **Save / share transferred notes** to create and
   share or save a ZIP archive.

The backup protocol may transfer data beyond Notes. The app asks before
starting and stores the transfer in its private app storage. It removes the
temporary full backup after successful extraction. If a transfer fails, that
backup remains on the phone until you choose **Delete local transfer and
pairing**. That action also deletes extracted notes, the ZIP archive, and
pairing credentials. Sharing the ZIP sends its contents to the destination you
choose.

## Limitations

- Only data included in the iPhone's backup can be retrieved. Cloud-only notes,
  enterprise restrictions, or changes in iOS's backup format may limit results.
- Encrypted device backups are detected and rejected; the app will not disable
  backup encryption. Password-based backup decryption and locked-note
  decryption are not supported.
- Note text is decoded, but rich-text rendering and attachment placement are
  not implemented. The ZIP preserves the Notes data and original attachment
  files.
- Force-stopping the app or disconnecting the cable interrupts a transfer.

## Get the app

Download the [ARM64 sideload APK](https://github.com/Opzet/apple-notes-exporter/raw/refs/heads/android-usb-apk-v0.1.0/NotesCableTransfer-arm64.apk)
and [verify its SHA-256 checksum](https://github.com/Opzet/apple-notes-exporter/raw/refs/heads/android-usb-apk-v0.1.0/SHA256SUMS).
Android may ask you to allow installation from the browser or file manager.
This test build uses a local debug signing key, not a production release key.

The [Android USB APK workflow](https://github.com/Opzet/apple-notes-exporter/actions/workflows/android-usb.yml)
also builds the app and publishes the APK and checksum as an Actions artifact.

## Build and validate

Build requirements and full instructions are in [`Maui/README.md`](Maui/README.md).
In brief, on Linux with .NET 10, JDK 21, the Android SDK and NDK, and the native
build prerequisites installed:

```sh
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"
export JAVA_HOME=/path/to/jdk-21
dotnet workload install maui-android
make build
```

The ARM64 APK is written under
`Maui/AppleNotes.Android/bin/Release/net10.0-android/android-arm64/publish/`.

The portable parser checks can be run without an Android device:

```sh
dotnet run --project Maui/AppleNotes.Core.Tests --configuration Release
```

Passing these checks does not replace testing with a real iPhone and Android
device. See [`Maui/README.md`](Maui/README.md) for privacy details, dependency
licenses, and device-testing guidance.

## Original macOS exporter

This repository also contains the original Swift macOS Apple Notes exporter.
That separate app reads Notes from a Mac and includes export formats and
automation interfaces that are not part of Notes Cable Transfer. Its source is
under [`Apple Notes Exporter/`](Apple%20Notes%20Exporter/).

## License

This project is licensed under the GNU General Public License v3.0. See
[`LICENSE`](LICENSE).
