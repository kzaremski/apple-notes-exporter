using System.Text;
using Android.Database.Sqlite;
using AppleNotes.Core;

namespace AppleNotes.AndroidApp.Platforms.Android;

internal static class BackupReader
{
    public static TransferResult Read(string backupRoot, string destination, CancellationToken cancellationToken)
    {
        var manifests = Directory.GetFiles(backupRoot, "Manifest.db", SearchOption.AllDirectories);
        if (manifests.Length != 1)
            throw new InvalidDataException("The iPhone did not produce exactly one readable backup manifest.");
        var backup = Path.GetDirectoryName(manifests[0])!;
        using var manifest = SQLiteDatabase.OpenDatabase(manifests[0], null, DatabaseOpenFlags.OpenReadonly)
            ?? throw new InvalidDataException("The backup manifest could not be opened.");
        using (var files = manifest.RawQuery("SELECT fileID, relativePath FROM Files WHERE domain = ? AND flags = 1",
                   [BackupPaths.NotesDomain]))
        {
            while (files.MoveToNext())
            {
                cancellationToken.ThrowIfCancellationRequested();
                var source = BackupPaths.ResolveFile(backup, files.GetString(0)!);
                var target = BackupPaths.ResolveRelative(destination, files.GetString(1)!);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.Copy(source, target, overwrite: false);
            }
        }

        var databasePath = Path.Combine(destination, "NoteStore.sqlite");
        if (!File.Exists(databasePath))
            throw new InvalidDataException("No NoteStore.sqlite was included in this iPhone backup. " +
                "Cloud-only Notes and accounts excluded by iOS cannot be retrieved by the backup protocol.");
        // A writable private copy allows SQLite to replay an accompanying WAL.
        using var db = SQLiteDatabase.OpenDatabase(databasePath, null, DatabaseOpenFlags.OpenReadwrite)
            ?? throw new InvalidDataException("The Notes database could not be opened.");
        var columns = Columns(db, "ZICCLOUDSYNCINGOBJECT");
        if (!columns.Contains("ZTITLE1") || Columns(db, "ZICNOTEDATA").Count == 0)
            throw new InvalidDataException("This iOS Notes database schema is not supported.");
        var folder = columns.Contains("ZFOLDER") ? "ZFOLDER" :
            columns.Contains("ZFOLDER2") ? "ZFOLDER2" : null;
        var folderTitle = columns.Contains("ZTITLE2") ? "COALESCE(f.ZTITLE2, 'Notes')" : "'Notes'";
        var locked = columns.Contains("ZISPASSWORDPROTECTED") ? "COALESCE(n.ZISPASSWORDPROTECTED, 0)" : "0";
        var deleted = columns.Contains("ZMARKEDFORDELETION") ? "COALESCE(n.ZMARKEDFORDELETION, 0) = 0" : "1";
        var join = folder is null ? "" : $"LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.{folder}";
        if (folder is null)
            folderTitle = "'Notes'";
        using var rows = db.RawQuery($"""
            SELECT n.Z_PK, COALESCE(n.ZTITLE1, 'Untitled'), {folderTitle}, d.ZDATA, {locked}
            FROM ZICCLOUDSYNCINGOBJECT n
            LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
            {join}
            WHERE (n.ZTITLE1 IS NOT NULL OR d.ZNOTE IS NOT NULL) AND {deleted}
            ORDER BY n.Z_PK
            """, null);
        var notes = new List<Note>();
        while (rows.MoveToNext())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var id = rows.GetLong(0).ToString(System.Globalization.CultureInfo.InvariantCulture);
            var title = rows.GetString(1)!;
            var folderName = rows.GetString(2)!;
            string text = "";
            string? error = null;
            if (rows.GetInt(4) != 0)
                error = "Locked note: unlocking/decryption is not supported.";
            else if (rows.IsNull(3))
                error = "Note body was not included in the backup.";
            else
            {
                try
                {
                    text = NoteBody.Decode(rows.GetBlob(3)!);
                }
                catch (Exception exception) when (exception is InvalidDataException or DecoderFallbackException)
                {
                    error = $"Could not decode note: {exception.Message}";
                }
            }
            notes.Add(new Note(id, title, folderName, text, error));
        }
        return new TransferResult(notes, destination);
    }

    private static HashSet<string> Columns(SQLiteDatabase db, string table)
    {
        using var rows = db.RawQuery($"PRAGMA table_info({table})", null);
        var columns = new HashSet<string>(StringComparer.Ordinal);
        while (rows.MoveToNext())
            columns.Add(rows.GetString(1)!);
        return columns;
    }
}
