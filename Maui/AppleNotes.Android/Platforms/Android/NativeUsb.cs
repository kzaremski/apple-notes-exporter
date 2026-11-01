using System.Runtime.InteropServices;

namespace AppleNotes.AndroidApp.Platforms.Android;

internal static class NativeUsb
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void Progress([MarshalAs(UnmanagedType.LPUTF8Str)] string message);

    [DllImport("notesusb", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int notes_transfer(int usbFd,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string privateDirectory,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string backupDirectory, Progress callback);

    [DllImport("notesusb", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void notes_cancel();
}
