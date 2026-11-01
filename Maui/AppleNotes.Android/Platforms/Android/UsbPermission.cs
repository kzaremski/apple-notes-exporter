using Android.App;
using Android.Content;
using Android.Hardware.Usb;
using Android.OS;

namespace AppleNotes.AndroidApp.Platforms.Android;

internal static class UsbPermission
{
    public static UsbDevice? Device { get; private set; }

    public static async Task RequestAsync()
    {
        var context = global::Android.App.Application.Context;
        var manager = (UsbManager)context.GetSystemService(Context.UsbService)!;
        var devices = manager.DeviceList?.Values.Where(device => device.VendorId == 0x05ac).ToList() ?? [];
        if (devices.Count != 1)
            throw new InvalidOperationException(devices.Count == 0
                ? "No iPhone detected. Use a data cable/OTG adapter, unlock the iPhone, and set Android to control USB."
                : "Connect only one Apple USB device at a time.");

        var device = devices[0];
        if (!manager.HasPermission(device))
        {
            var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var action = $"{context.PackageName}.USB_PERMISSION.{Guid.NewGuid():N}";
            using var receiver = new PermissionReceiver(action, completion);
            if (Build.VERSION.SdkInt >= BuildVersionCodes.Tiramisu)
                context.RegisterReceiver(receiver, new IntentFilter(action), ReceiverFlags.NotExported);
            else
                context.RegisterReceiver(receiver, new IntentFilter(action));
            try
            {
                using var intent = new Intent(action).SetPackage(context.PackageName);
                // UsbManager adds device and grant extras to this package-scoped pending intent.
                using var pending = PendingIntent.GetBroadcast(context, 0, intent,
                    PendingIntentFlags.CancelCurrent | PendingIntentFlags.Mutable)!;
                manager.RequestPermission(device, pending);
                if (!await completion.Task.WaitAsync(TimeSpan.FromMinutes(2)))
                    throw new UnauthorizedAccessException("USB access was denied. Allow access to connect to the iPhone.");
            }
            catch (TimeoutException exception)
            {
                throw new IOException("USB permission timed out. Reconnect the cable and try again.", exception);
            }
            finally
            {
                context.UnregisterReceiver(receiver);
            }
        }
        Device = device;
    }

    private sealed class PermissionReceiver(string action, TaskCompletionSource<bool> completion) : BroadcastReceiver
    {
        public override void OnReceive(Context? context, Intent? intent)
        {
            if (intent?.Action == action)
                completion.TrySetResult(intent.GetBooleanExtra(UsbManager.ExtraPermissionGranted, false));
        }
    }
}
