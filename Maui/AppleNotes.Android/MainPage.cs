using AppleNotes.AndroidApp.Platforms.Android;

namespace AppleNotes.AndroidApp;

public sealed class MainPage : ContentPage
{
    private readonly Label status = new() { Text = "Connect an unlocked iPhone to this Android phone with a data-capable USB cable." };
    private readonly Button transfer = new() { Text = "Transfer from iPhone" };
    private readonly Button cancel = new() { Text = "Cancel", IsVisible = false };
    private readonly Button share = new() { Text = "Save / share transferred notes", IsEnabled = false };
    private readonly Button erase = new() { Text = "Delete local transfer and pairing", TextColor = Colors.DarkRed };
    private readonly ActivityIndicator busy = new();
    private readonly CollectionView notes = new() { SelectionMode = SelectionMode.None };

    public MainPage()
    {
        Title = "Notes Cable Transfer";
        transfer.Clicked += TransferClicked;
        cancel.Clicked += (_, _) => TransferSession.Cancel();
        share.Clicked += ShareClicked;
        erase.Clicked += EraseClicked;
        notes.ItemTemplate = new DataTemplate(() =>
        {
            var title = new Label { FontAttributes = FontAttributes.Bold };
            title.SetBinding(Label.TextProperty, "Title");
            var body = new Label { MaxLines = 4, LineBreakMode = LineBreakMode.TailTruncation };
            body.SetBinding(Label.TextProperty, "Text");
            var error = new Label { TextColor = Colors.DarkRed };
            error.SetBinding(Label.TextProperty, "Error");
            return new VerticalStackLayout { Padding = 12, Children = { title, body, error } };
        });
        var instructions = new Label
        {
            Text = "No computer or root required. Android must support USB host/OTG and be the USB host. " +
                "Unlock the iPhone, accept Trust, and enter its passcode when asked. " +
                "This experimental app uses an on-device iPhone backup; it may temporarily need space for a full backup. " +
                "Only Notes data is kept after success. Encrypted backups and locked notes are not yet supported. " +
                "Notes not included in the iPhone's backup cannot be transferred.",
            FontSize = 13
        };
        var layout = new Grid
        {
            Padding = 20,
            RowSpacing = 12,
            RowDefinitions =
            {
                new(GridLength.Auto), new(GridLength.Auto), new(GridLength.Auto),
                new(GridLength.Auto), new(GridLength.Star), new(GridLength.Auto)
            }
        };
        layout.Add(new Label { Text = "iPhone → Android", FontSize = 28, FontAttributes = FontAttributes.Bold }, 0, 0);
        layout.Add(instructions, 0, 1);
        layout.Add(new HorizontalStackLayout { Spacing = 8, Children = { transfer, cancel, busy } }, 0, 2);
        layout.Add(status, 0, 3);
        layout.Add(notes, 0, 4);
        layout.Add(new VerticalStackLayout { Children = { share, erase } }, 0, 5);
        Content = layout;
    }

    protected override void OnAppearing()
    {
        base.OnAppearing();
        TransferSession.Changed += SessionChanged;
        Refresh();
    }

    protected override void OnDisappearing()
    {
        TransferSession.Changed -= SessionChanged;
        base.OnDisappearing();
    }

    private void SessionChanged() => MainThread.BeginInvokeOnMainThread(Refresh);

    private void Refresh()
    {
        var running = TransferSession.IsRunning;
        transfer.IsEnabled = !running;
        cancel.IsVisible = running;
        erase.IsEnabled = !running;
        share.IsEnabled = !running && TransferSession.Result is not null;
        busy.IsRunning = running;
        if (TransferSession.Status is not null)
            status.Text = TransferSession.Status;
        notes.ItemsSource = TransferSession.Result?.Notes;
    }

    private async void TransferClicked(object? sender, EventArgs args)
    {
        if (!await DisplayAlertAsync("Create a local iPhone backup?",
            "The iPhone backup protocol can transfer data beyond Notes. It stays in this app's private storage " +
            "and is removed after Notes extraction. A failed transfer remains locally until you delete it. " +
            "Ensure sufficient free space and keep both phones connected.", "Transfer", "Cancel"))
            return;

        try
        {
            await UsbPermission.RequestAsync();
            TransferSession.Start();
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            status.Text = exception.Message;
        }
    }

    private async void ShareClicked(object? sender, EventArgs args)
    {
        try
        {
            var path = await TransferSession.CreateArchiveAsync();
            await Share.Default.RequestAsync(new ShareFileRequest("Apple Notes", new ShareFile(path, "application/zip")));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            await DisplayAlertAsync("Could not export notes", exception.Message, "OK");
        }
    }

    private async void EraseClicked(object? sender, EventArgs args)
    {
        if (!await DisplayAlertAsync("Delete local data?",
            "Delete this app's transferred notes, temporary backup, export archive, and iPhone pairing credentials? " +
            "Your iPhone is not changed.", "Delete", "Cancel"))
            return;
        try
        {
            TransferSession.Erase();
            Refresh();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            await DisplayAlertAsync("Could not delete local data", exception.Message, "OK");
        }
    }
}
