using System.IO.Compression;
using System.Text.Json;
using Android.Content;
using Android.Hardware.Usb;
using AppleNotes.Core;

namespace AppleNotes.AndroidApp.Platforms.Android;

internal static class TransferSession
{
    private static readonly string Root = Path.Combine(FileSystem.AppDataDirectory, "iphone-usb");
    private static readonly string Backup = Path.Combine(Root, "backup");
    private static readonly string Notes = Path.Combine(Root, "notes");
    private static readonly string Archive = Path.Combine(FileSystem.CacheDirectory, "Apple Notes.zip");
    private static readonly object Gate = new();
    private static bool cancelled;
    private static bool nativeRunning;
    private static readonly NativeUsb.Progress Progress = Update;

    public static bool IsRunning { get; private set; }
    public static string? Status { get; private set; }
    public static TransferResult? Result { get; private set; }
    public static event Action? Changed;

    public static void Start()
    {
        lock (Gate)
        {
            if (IsRunning)
                throw new InvalidOperationException("A transfer is already running.");
            IsRunning = true;
            cancelled = false;
        }
        Update("Starting USB transfer...");
        try
        {
            var context = global::Android.App.Application.Context;
            context.StartForegroundService(new Intent(context, typeof(TransferService)));
        }
        catch
        {
            IsRunning = false;
            Update("Android could not start the USB foreground service.");
            throw;
        }
    }

    public static async Task RunAsync()
    {
        try
        {
            await Task.Run(() =>
            {
                var context = global::Android.App.Application.Context;
                var manager = (UsbManager)context.GetSystemService(Context.UsbService)!;
                var device = UsbPermission.Device ?? throw new IOException("The iPhone was disconnected.");
                using var connection = manager.OpenDevice(device)
                    ?? throw new IOException("Android could not open the iPhone USB connection.");
                Directory.CreateDirectory(Root);
                Directory.CreateDirectory(Backup);
                int code;
                lock (Gate)
                {
                    if (cancelled)
                        throw new OperationCanceledException();
                    nativeRunning = true;
                }
                try
                {
                    code = NativeUsb.notes_transfer(connection.FileDescriptor, Root, Backup, Progress);
                }
                finally
                {
                    lock (Gate)
                        nativeRunning = false;
                }
                if (cancelled)
                    throw new OperationCanceledException();
                if (code != 0)
                    throw new IOException($"USB transfer failed (code {code}). {Status}");

                Update("Extracting Notes from the local backup...");
                var destination = Path.Combine(Root, $"notes-{Guid.NewGuid():N}");
                Directory.CreateDirectory(destination);
                var result = BackupReader.Read(Backup, destination);
                File.WriteAllText(Path.Combine(destination, "notes.json"), JsonSerializer.Serialize(result.Notes));
                if (Directory.Exists(Notes))
                    Directory.Delete(Notes, recursive: true);
                Directory.Move(destination, Notes);
                Result = result with { Directory = Notes };
                Directory.Delete(Backup, recursive: true);
                Update($"Transferred {result.Notes.Count} notes. {result.UnreadableCount} could not be decoded. " +
                    "Text is available below; the export also contains the original Notes files and attachments.");
            });
        }
        catch (OperationCanceledException)
        {
            Update("Transfer cancelled. Temporary data remains private; use Delete local transfer and pairing to remove it.");
        }
        catch (Exception exception)
        {
            Update($"Transfer failed: {exception.Message}");
        }
        finally
        {
            IsRunning = false;
            Changed?.Invoke();
        }
    }

    public static void Cancel()
    {
        lock (Gate)
        {
            cancelled = true;
            if (nativeRunning)
                NativeUsb.notes_cancel();
        }
        Update("Cancelling transfer...");
    }

    public static async Task<string> CreateArchiveAsync()
    {
        if (IsRunning || Result is null)
            throw new InvalidOperationException("Complete a notes transfer before exporting.");
        await Task.Run(() =>
        {
            File.Delete(Archive);
            ZipFile.CreateFromDirectory(Notes, Archive);
        });
        return Archive;
    }

    public static void Erase()
    {
        if (IsRunning)
            throw new InvalidOperationException("Cancel the transfer before deleting its data.");
        if (Directory.Exists(Root))
            Directory.Delete(Root, recursive: true);
        File.Delete(Archive);
        Result = null;
        Update("Local notes, backup, export, and pairing credentials deleted.");
    }

    private static void Update(string message)
    {
        Status = message;
        Changed?.Invoke();
    }
}
