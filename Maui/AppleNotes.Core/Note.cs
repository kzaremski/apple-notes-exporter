namespace AppleNotes.Core;

public sealed record Note(string Id, string Title, string Folder, string Text, string? Error);

public sealed record TransferResult(IReadOnlyList<Note> Notes, string Directory)
{
    public int UnreadableCount => Notes.Count(note => note.Error is not null);
}
