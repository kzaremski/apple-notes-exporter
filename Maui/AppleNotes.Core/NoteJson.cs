using System.Text.Json.Serialization;

namespace AppleNotes.Core;

[JsonSerializable(typeof(Note[]))]
public partial class NoteJson : JsonSerializerContext;
