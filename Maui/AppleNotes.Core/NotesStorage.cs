namespace AppleNotes.Core;

public static class NotesStorage
{
    public static void Commit(string staging, string current)
    {
        if (!Directory.Exists(staging))
            throw new DirectoryNotFoundException("The extracted Notes directory is missing.");
        Recover(current);
        var previous = current + ".previous";
        if (Directory.Exists(previous))
            Directory.Delete(previous, recursive: true);
        if (Directory.Exists(current))
            Directory.Move(current, previous);
        try
        {
            Directory.Move(staging, current);
        }
        finally
        {
            Recover(current);
        }
        if (Directory.Exists(previous))
            Directory.Delete(previous, recursive: true);
    }

    public static void Recover(string current)
    {
        var previous = current + ".previous";
        if (!Directory.Exists(current) && Directory.Exists(previous))
            Directory.Move(previous, current);
    }
}
