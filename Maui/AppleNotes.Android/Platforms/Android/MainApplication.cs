using Android.App;
using Android.Runtime;

namespace AppleNotes.AndroidApp.Platforms.Android;

[Application]
public sealed class MainApplication(nint handle, JniHandleOwnership ownership)
    : MauiApplication(handle, ownership)
{
    protected override MauiApp CreateMauiApp() => MauiProgram.CreateMauiApp();
}
