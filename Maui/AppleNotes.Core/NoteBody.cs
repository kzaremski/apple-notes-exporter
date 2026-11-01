using System.IO.Compression;
using System.Text;

namespace AppleNotes.Core;

public static class NoteBody
{
    private const int MaximumBodySize = 32 * 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    // Field numbers come from the repository's notestore.proto.
    public static string Decode(byte[] compressed)
    {
        using var source = new MemoryStream(compressed, writable: false);
        using var gzip = new GZipStream(source, CompressionMode.Decompress);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        int read;
        while ((read = gzip.Read(buffer)) != 0)
        {
            if (output.Length + read > MaximumBodySize)
                throw new InvalidDataException("Note body exceeds the 32 MiB safety limit.");
            output.Write(buffer, 0, read);
        }

        var document = FindBytes(output.ToArray(), 2);
        var note = FindBytes(document, 3);
        return StrictUtf8.GetString(FindBytes(note, 2));
    }

    private static ReadOnlySpan<byte> FindBytes(ReadOnlySpan<byte> data, ulong wanted)
    {
        while (!data.IsEmpty)
        {
            var tag = ReadVarint(ref data);
            if (tag >> 3 == 0)
                throw new InvalidDataException("Invalid protobuf field number.");
            switch (tag & 7)
            {
                case 0:
                    ReadVarint(ref data);
                    break;
                case 1:
                    Consume(ref data, sizeof(ulong));
                    break;
                case 2:
                    var size = ReadVarint(ref data);
                    if (size > (ulong)data.Length)
                        throw new InvalidDataException("Truncated note field.");
                    var value = data[..(int)size];
                    data = data[(int)size..];
                    if (tag >> 3 == wanted)
                        return value;
                    break;
                case 5:
                    Consume(ref data, sizeof(uint));
                    break;
                default:
                    throw new InvalidDataException("Unsupported protobuf wire type.");
            }
        }
        throw new InvalidDataException($"Missing note field {wanted}.");
    }

    private static ReadOnlySpan<byte> Consume(ref ReadOnlySpan<byte> data, int length)
    {
        if (length > data.Length)
            throw new InvalidDataException("Truncated note data.");
        var value = data[..length];
        data = data[length..];
        return value;
    }

    private static ulong ReadVarint(ref ReadOnlySpan<byte> data)
    {
        ulong value = 0;
        for (var shift = 0; shift < 70; shift += 7)
        {
            if (data.IsEmpty)
                throw new InvalidDataException("Truncated protobuf integer.");
            var next = data[0];
            data = data[1..];
            if (shift == 63 && next > 1)
                throw new InvalidDataException("Overflowing protobuf integer.");
            value |= (ulong)(next & 0x7f) << shift;
            if (next < 0x80)
                return value;
        }
        throw new InvalidDataException("Invalid protobuf integer.");
    }
}
