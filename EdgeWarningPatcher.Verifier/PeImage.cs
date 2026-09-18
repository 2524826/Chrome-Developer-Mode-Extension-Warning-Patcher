using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace EdgeWarningPatcher.Verifier;

public sealed record PeSection(string Name, int VirtualAddress, int VirtualSize,
    int RawOffset, int RawSize);

public sealed class PeImage {
    public const ushort MachineAmd64 = 0x8664;

    private PeImage(ushort machine, IReadOnlyList<PeSection> sections) {
        this.Machine = machine;
        this.Sections = sections;
    }

    public ushort Machine { get; }
    public IReadOnlyList<PeSection> Sections { get; }

    public static PeImage Read(Stream stream) {
        if (!stream.CanRead || !stream.CanSeek) {
            throw new InvalidDataException("PE stream must be readable and seekable.");
        }
        using BinaryReader reader = new(stream, Encoding.ASCII, leaveOpen: true);
        if (stream.Length < 0x40 || reader.ReadUInt16() != 0x5A4D) {
            throw new InvalidDataException("File is not a PE image (missing MZ header).");
        }

        stream.Position = 0x3C;
        uint peOffset = reader.ReadUInt32();
        if (peOffset > stream.Length - 24) {
            throw new InvalidDataException("PE header offset is outside the file.");
        }
        stream.Position = peOffset;
        if (reader.ReadUInt32() != 0x00004550) {
            throw new InvalidDataException("File is not a PE image (missing PE signature).");
        }

        ushort machine = reader.ReadUInt16();
        ushort sectionCount = reader.ReadUInt16();
        stream.Position += 12;
        ushort optionalHeaderSize = reader.ReadUInt16();
        stream.Position += 2;
        long sectionTable = peOffset + 24L + optionalHeaderSize;
        if (sectionCount == 0 || sectionCount > 96 ||
            sectionTable > stream.Length - sectionCount * 40L) {
            throw new InvalidDataException("PE section table is invalid.");
        }

        List<PeSection> sections = new(sectionCount);
        stream.Position = sectionTable;
        for (int index = 0; index < sectionCount; index++) {
            byte[] nameBytes = reader.ReadBytes(8);
            string name = Encoding.ASCII.GetString(nameBytes).TrimEnd('\0');
            int virtualSize = checked((int)reader.ReadUInt32());
            int virtualAddress = checked((int)reader.ReadUInt32());
            int rawSize = checked((int)reader.ReadUInt32());
            int rawOffset = checked((int)reader.ReadUInt32());
            stream.Position += 16;

            if (rawOffset < 0 || rawSize < 0 || rawOffset > stream.Length - rawSize) {
                throw new InvalidDataException($"PE section '{name}' exceeds file bounds.");
            }
            sections.Add(new PeSection(name, virtualAddress, virtualSize, rawOffset, rawSize));
        }
        return new PeImage(machine, sections);
    }
}
