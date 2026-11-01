using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.OS;

namespace AppleNotes.AndroidApp.Platforms.Android;

[Service(Exported = false, ForegroundServiceType = ForegroundService.TypeConnectedDevice)]
public sealed class TransferService : Service
{
    private const string Channel = "notes-usb";
    private bool started;

    public override IBinder? OnBind(Intent? intent) => null;

    public override StartCommandResult OnStartCommand(Intent? intent, StartCommandFlags flags, int startId)
    {
        var notifications = (NotificationManager)GetSystemService(NotificationService)!;
        notifications.CreateNotificationChannel(new NotificationChannel(Channel, "iPhone notes transfer", NotificationImportance.Low));
        using var open = new Intent(this, typeof(MainActivity));
        using var pending = PendingIntent.GetActivity(this, 0, open, PendingIntentFlags.Immutable);
        using var notification = new Notification.Builder(this, Channel)
            .SetContentTitle("Transferring iPhone notes")
            .SetContentText("Keep the USB cable connected. Tap to see progress.")
            .SetSmallIcon(global::Android.Resource.Drawable.StatSysDownload)
            .SetContentIntent(pending)
            .SetOngoing(true)
            .Build();
        StartForeground(1, notification);
        if (!started)
        {
            started = true;
            _ = RunAsync();
        }
        return StartCommandResult.NotSticky;
    }

    private async Task RunAsync()
    {
        try
        {
            await TransferSession.RunAsync();
        }
        finally
        {
            StopForeground(StopForegroundFlags.Remove);
            StopSelf();
        }
    }

    public override void OnDestroy()
    {
        if (TransferSession.IsRunning)
            TransferSession.Cancel();
        base.OnDestroy();
    }
}
