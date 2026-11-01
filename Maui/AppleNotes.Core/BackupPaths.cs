namespace AppleNotes.Core;

public static class BackupPaths
{
    public const string NotesDomain = "AppDomainGroup-group.com.apple.notes";

    public static string ResolveFile(string backup, string fileId)
    {
        if (fileId.Length != 40 || !fileId.All(char.IsAsciiHexDigit))
            throw new InvalidDataException("The backup manifest contains an invalid file ID.");
        var sharded = Path.Combine(backup, fileId[..2], fileId);
        return File.Exists(sharded) ? sharded : Path.Combine(backup, fileId);
    }

    public static string ResolveRelative(string root, string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || relative.Contains('\\') ||
            Path.IsPathRooted(relative) || relative.Split('/').Any(part => part is "." or ".." or ""))
            throw new InvalidDataException("The backup contains an unsafe relative path.");

        var prefix = Path.GetFullPath(root) + Path.DirectorySeparatorChar;
        var path = Path.GetFullPath(Path.Combine(root, relative));
        if (!path.StartsWith(prefix, StringComparison.Ordinal))
            throw new InvalidDataException("The backup path escapes its destination.");
        return path;
    }
}
