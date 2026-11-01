using Android.App;
using Android.Content.PM;

namespace AppleNotes.AndroidApp.Platforms.Android;

[Activity(MainLauncher = true, Exported = true, Theme = "@style/Maui.MainTheme",
    ConfigurationChanges = ConfigChanges.ScreenSize | ConfigChanges.Orientation |
        ConfigChanges.UiMode | ConfigChanges.ScreenLayout | ConfigChanges.SmallestScreenSize |
        ConfigChanges.Density)]
public sealed class MainActivity : MauiAppCompatActivity;
