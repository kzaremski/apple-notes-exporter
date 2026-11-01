using System.IO.Compression;
using System.Text;
using AppleNotes.Core;

var passed = 0;
Test("Decodes the repository protobuf envelope", () =>
{
    var body = Encoding.UTF8.GetBytes("Hello\nChecklists and café 🎉");
    var envelope = Field(2, Field(3, Field(2, body)));
    Equal("Hello\nChecklists and café 🎉", NoteBody.Decode(Gzip(envelope)));
});
Test("Reads an empty note", () =>
    Equal("", NoteBody.Decode(Gzip(Field(2, Field(3, Field(2, [])))))));
Test("Skips unknown fields", () =>
    Equal("abc", NoteBody.Decode(Gzip([0x08, 0x01, .. Field(2, [0x10, 0x01, .. Field(3, Field(2, "abc"u8.ToArray()))])]))));
Test("Rejects a truncated protobuf", () =>
    Throws<InvalidDataException>(() => NoteBody.Decode(Gzip([0x12, 0x7f, 0x01]))));
Test("Rejects missing text instead of reporting an empty success", () =>
    Throws<InvalidDataException>(() => NoteBody.Decode(Gzip(Field(2, Field(3, []))))));
Test("Rejects invalid UTF-8", () =>
{
    var envelope = Field(2, Field(3, Field(2, [0xff])));
    Throws<DecoderFallbackException>(() => NoteBody.Decode(Gzip(envelope)));
});
Test("Rejects overflowing varints", () =>
{
    byte[] envelope = [0x12, .. Enumerable.Repeat((byte)0xff, 10)];
    Throws<InvalidDataException>(() => NoteBody.Decode(Gzip(envelope)));
});
Test("Bounds decompression", () =>
    Throws<InvalidDataException>(() => NoteBody.Decode(Gzip(new byte[32 * 1024 * 1024 + 1]))));
Test("Rejects malformed gzip", () => Throws<InvalidDataException>(() => NoteBody.Decode([1, 2, 3, 4])));
Test("Rejects unsafe backup paths", () =>
{
    foreach (var path in new[] { "../secret", "/etc/passwd", "a/../b", @"a\..\b", "a//b", ".", "" })
        Throws<InvalidDataException>(() => BackupPaths.ResolveRelative("/private/notes", path));
});
Test("Resolves attachment paths inside the Notes directory", () =>
    Equal("/private/notes/Accounts/123/Media/photo.jpg",
        BackupPaths.ResolveRelative("/private/notes", "Accounts/123/Media/photo.jpg")));
Test("Rejects invalid backup file IDs", () =>
{
    foreach (var id in new[] { "../../etc/passwd", new string('z', 40), "" })
        Throws<InvalidDataException>(() => BackupPaths.ResolveFile("/private/backup", id));
});
Test("Supports sharded and flat backup layouts", () =>
{
    var root = Path.Combine(Path.GetTempPath(), $"notes-test-{Guid.NewGuid():N}");
    const string id = "0123456789abcdef0123456789abcdef01234567";
    Directory.CreateDirectory(Path.Combine(root, "01"));
    try
    {
        Equal(Path.Combine(root, id), BackupPaths.ResolveFile(root, id));
        File.WriteAllText(Path.Combine(root, "01", id), "");
        Equal(Path.Combine(root, "01", id), BackupPaths.ResolveFile(root, id));
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
});
Test("Commits a new transfer without mixing old Notes files", () =>
{
    var root = Path.Combine(Path.GetTempPath(), $"notes-commit-{Guid.NewGuid():N}");
    var current = Path.Combine(root, "notes");
    var staging = Path.Combine(root, "staging");
    Directory.CreateDirectory(current);
    Directory.CreateDirectory(staging);
    try
    {
        File.WriteAllText(Path.Combine(current, "old"), "old");
        File.WriteAllText(Path.Combine(staging, "new"), "new");
        NotesStorage.Commit(staging, current);
        Equal("new", File.ReadAllText(Path.Combine(current, "new")));
        if (File.Exists(Path.Combine(current, "old")) || Directory.Exists(current + ".previous"))
            throw new Exception("Stale Notes files survived commit.");
        Throws<DirectoryNotFoundException>(() => NotesStorage.Commit(staging, current));
        Equal("new", File.ReadAllText(Path.Combine(current, "new")));
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
});
Test("Recovers a transfer interrupted during directory replacement", () =>
{
    var root = Path.Combine(Path.GetTempPath(), $"notes-recover-{Guid.NewGuid():N}");
    var current = Path.Combine(root, "notes");
    Directory.CreateDirectory(current + ".previous");
    try
    {
        File.WriteAllText(Path.Combine(current + ".previous", "saved"), "saved");
        NotesStorage.Recover(current);
        Equal("saved", File.ReadAllText(Path.Combine(current, "saved")));
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
});
Console.WriteLine($"{passed} checks passed.");

void Test(string name, Action action)
{
    action();
    passed++;
    Console.WriteLine($"PASS {name}");
}

static void Equal(string expected, string actual)
{
    if (expected != actual)
        throw new Exception($"Expected {expected}, got {actual}");
}

static void Throws<T>(Action action) where T : Exception
{
    try { action(); }
    catch (T) { return; }
    throw new Exception($"Expected {typeof(T).Name}");
}

static byte[] Field(byte field, byte[] bytes)
{
    if (bytes.Length >= 128)
        throw new ArgumentOutOfRangeException(nameof(bytes));
    return [(byte)((field << 3) | 2), (byte)bytes.Length, .. bytes];
}

static byte[] Gzip(byte[] bytes)
{
    using var output = new MemoryStream();
    using (var gzip = new GZipStream(output, CompressionMode.Compress, leaveOpen: true))
        gzip.Write(bytes);
    return output.ToArray();
}
