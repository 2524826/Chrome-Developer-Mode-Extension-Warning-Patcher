using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;

namespace EdgeWarningPatcher.Verifier;

public static class PatchVerifier {
    public static VerificationReport Verify(string modulePath, PatchRule rule,
        string browser, string version) {
        string moduleHash = string.Empty;
        VerificationReport Fail(string reason, int matchCount = 0, int? rva = null,
            long? offset = null, IReadOnlyList<PlannedWrite>? writes = null) =>
            new(false, rule.Id, browser, version, modulePath, moduleHash, rule.Section,
                matchCount, rva, offset, writes ?? Array.Empty<PlannedWrite>(), reason);

        if (!File.Exists(modulePath)) {
            return Fail("target does not exist; no files were modified");
        }
        try {
            moduleHash = Sha256(modulePath);
        } catch (IOException exception) {
            return Fail($"target cannot be read: {exception.Message}; no files were modified");
        }
        if (!browser.Equals(rule.Browser, StringComparison.OrdinalIgnoreCase)) {
            return Fail($"browser '{browser}' does not match required '{rule.Browser}'; no files were modified");
        }
        if (!Path.GetFileName(modulePath).Equals(rule.Module, StringComparison.OrdinalIgnoreCase)) {
            return Fail($"module '{Path.GetFileName(modulePath)}' does not match required '{rule.Module}'; no files were modified");
        }
        if (!VersionInRange(version, rule.MinimumVersion, rule.MaximumVersion)) {
            return Fail($"version '{version}' is outside [{rule.MinimumVersion}, {rule.MaximumVersion}]; no files were modified");
        }

        using FileStream stream = new(modulePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        PeImage image;
        try {
            image = PeImage.Read(stream);
        } catch (Exception exception) when (exception is InvalidDataException or IOException or OverflowException) {
            return Fail($"invalid PE: {exception.Message}; no files were modified");
        }
        if (!rule.Architecture.Equals("x64", StringComparison.OrdinalIgnoreCase) ||
            image.Machine != PeImage.MachineAmd64) {
            return Fail("target is not an x64 PE; no files were modified");
        }

        PeSection[] sections = image.Sections.Where(candidate => candidate.Name == rule.Section).ToArray();
        if (sections.Length != 1) {
            return Fail($"expected exactly one section '{rule.Section}', found {sections.Length}; no files were modified");
        }
        PeSection section = sections[0];
        byte[] sectionBytes = new byte[section.RawSize];
        try {
            stream.Position = section.RawOffset;
            ReadExactly(stream, sectionBytes);
        } catch (IOException exception) {
            return Fail($"section '{rule.Section}' cannot be read: {exception.Message}; no files were modified");
        }
        IReadOnlyList<int> matches = rule.Pattern.FindAll(sectionBytes);
        if (matches.Count != rule.ExpectedMatches) {
            return Fail($"Rule {rule.Id} expected exactly {rule.ExpectedMatches} match(es) in {rule.Module}:{rule.Section}, but found {matches.Count}. No files were modified.", matches.Count);
        }

        int match = matches.Single();
        int matchRva = checked(section.VirtualAddress + match);
        long matchFileOffset = checked((long)section.RawOffset + match);
        List<PlannedWrite> planned = new();
        foreach (PatchWrite write in rule.Writes) {
            long writeEnd = (long)match + write.Offset + write.Expected.Length;
            if (writeEnd > sectionBytes.Length) {
                return Fail($"write offset 0x{write.Offset:X} exceeds section bounds; no files were modified",
                    matches.Count, matchRva, matchFileOffset, planned);
            }
            ReadOnlySpan<byte> actual = sectionBytes.AsSpan(match + write.Offset, write.Expected.Length);
            if (actual.SequenceEqual(write.Replacement)) {
                return Fail($"rule is already patched at offset 0x{write.Offset:X}; no files were modified",
                    matches.Count, matchRva, matchFileOffset, planned);
            }
            if (!actual.SequenceEqual(write.Expected)) {
                return Fail($"original bytes differ at offset 0x{write.Offset:X}; no files were modified",
                    matches.Count, matchRva, matchFileOffset, planned);
            }
            planned.Add(new PlannedWrite(matchFileOffset + write.Offset,
                matchRva + write.Offset, Convert.ToHexString(write.Expected),
                Convert.ToHexString(write.Replacement)));
        }

        if (rule.ContextSha256 is not null) {
            string context = Convert.ToHexString(SHA256.HashData(sectionBytes.AsSpan(match, rule.Pattern.Length)));
            if (!context.Equals(rule.ContextSha256, StringComparison.OrdinalIgnoreCase)) {
                return Fail("context SHA-256 differs; no files were modified", matches.Count,
                    matchRva, matchFileOffset, planned);
            }
        }
        return new VerificationReport(true, rule.Id, browser, version, modulePath,
            moduleHash, rule.Section, matches.Count, matchRva, matchFileOffset,
            planned, "all safety gates passed; dry-run only; no files were modified");
    }

    private static string Sha256(string path) {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);
        using SHA256 sha256 = SHA256.Create();
        return Convert.ToHexString(sha256.ComputeHash(stream));
    }

    private static void ReadExactly(Stream stream, byte[] buffer) {
        int offset = 0;
        while (offset < buffer.Length) {
            int read = stream.Read(buffer, offset, buffer.Length - offset);
            if (read == 0) {
                throw new EndOfStreamException("Unexpected end of stream.");
            }
            offset += read;
        }
    }

    private static bool VersionInRange(string actualText, string minimumText,
        string maximumText) {
        if (!Version.TryParse(actualText, out Version? actual) ||
            !Version.TryParse(minimumText, out Version? minimum) || actual < minimum) {
            return false;
        }
        if (maximumText == "*") {
            return true;
        }
        if (maximumText.EndsWith(".*", StringComparison.Ordinal)) {
            return int.TryParse(maximumText[..^2], out int maximumMajor) &&
                actual.Major == maximumMajor;
        }
        return Version.TryParse(maximumText, out Version? maximum) && actual <= maximum;
    }
}
