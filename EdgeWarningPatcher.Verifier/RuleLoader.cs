using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Xml.Linq;

namespace EdgeWarningPatcher.Verifier;

public static class RuleLoader {
    private static readonly HashSet<string> TargetAttributes = new(StringComparer.Ordinal) {
        "id", "browser", "module", "arch", "minVersion", "maxVersion",
        "section", "expectedMatches", "contextSha256"
    };
    private static readonly HashSet<string> WriteAttributes = new(StringComparer.Ordinal) {
        "offset", "expected", "replacement"
    };

    public static IReadOnlyList<PatchRule> Load(string path) {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Load(stream);
    }

    public static IReadOnlyList<PatchRule> Load(Stream stream) {
        XDocument document = XDocument.Load(stream, LoadOptions.SetLineInfo);
        XElement root = document.Root ?? throw new FormatException("Rules XML has no root element.");
        XElement[] targetSets = root.Elements("PatchTargets").ToArray();
        if (targetSets.Length > 1) {
            throw new FormatException("Rules XML contains more than one PatchTargets element.");
        }
        XElement? targets = targetSets.SingleOrDefault();
        if (targets is null) {
            return Array.Empty<PatchRule>();
        }
        RejectUnknownAttributes(targets, new HashSet<string>(StringComparer.Ordinal) { "schemaVersion" });
        if ((string?)targets.Attribute("schemaVersion") != "1") {
            throw new FormatException("PatchTargets schemaVersion must be '1'.");
        }

        List<PatchRule> rules = new();
        HashSet<string> ids = new(StringComparer.Ordinal);
        foreach (XElement target in targets.Elements()) {
            if (target.Name != "PatchTarget") {
                throw new FormatException($"Unknown PatchTargets element '{target.Name}'.");
            }
            RejectUnknownAttributes(target, TargetAttributes);
            string id = Required(target, "id");
            if (!ids.Add(id)) {
                throw new FormatException($"Duplicate patch rule id '{id}'.");
            }

            XElement[] patterns = target.Elements("BytePattern").ToArray();
            if (patterns.Length != 1 ||
                target.Elements().Any(element => element.Name.LocalName is not ("BytePattern" or "Write"))) {
                throw new FormatException($"Rule '{id}' must have one BytePattern and only Write children.");
            }
            if (patterns[0].HasAttributes) {
                throw new FormatException($"Rule '{id}' BytePattern cannot have attributes.");
            }

            int expectedMatches = ParsePositiveInt(Required(target, "expectedMatches"), "expectedMatches");
            if (expectedMatches != 1) {
                throw new FormatException($"Rule '{id}' expectedMatches must be exactly 1.");
            }
            AobPattern pattern = AobPattern.Parse(patterns[0].Value);
            List<PatchWrite> writes = target.Elements("Write").Select(write => {
                RejectUnknownAttributes(write, WriteAttributes);
                if (write.HasElements || !string.IsNullOrWhiteSpace(write.Value)) {
                    throw new FormatException($"Rule '{id}' Write elements cannot have content.");
                }
                int offset = ParseNonNegativeInt(Required(write, "offset"), "offset");
                byte[] expected = ParseHexBytes(Required(write, "expected"));
                byte[] replacement = ParseHexBytes(Required(write, "replacement"));
                if (expected.Length == 0 || expected.Length != replacement.Length) {
                    throw new FormatException($"Rule '{id}' Write byte lengths must be equal and non-zero.");
                }
                return new PatchWrite(offset, expected, replacement);
            }).ToList();
            if (writes.Count == 0) {
                throw new FormatException($"Rule '{id}' has no writes.");
            }
            foreach (PatchWrite write in writes) {
                if ((long)write.Offset + write.Expected.Length > pattern.Length) {
                    throw new FormatException($"Rule '{id}' write at 0x{write.Offset:X} exceeds its BytePattern.");
                }
            }
            for (int left = 0; left < writes.Count; left++) {
                for (int right = left + 1; right < writes.Count; right++) {
                    int leftEnd = writes[left].Offset + writes[left].Expected.Length;
                    int rightEnd = writes[right].Offset + writes[right].Expected.Length;
                    if (writes[left].Offset < rightEnd && writes[right].Offset < leftEnd) {
                        throw new FormatException($"Rule '{id}' contains overlapping writes.");
                    }
                }
            }

            string? contextSha256 = (string?)target.Attribute("contextSha256");
            if (contextSha256 is not null &&
                (contextSha256.Length != 64 || !contextSha256.All(Uri.IsHexDigit))) {
                throw new FormatException($"Rule '{id}' contextSha256 must contain 64 hexadecimal characters.");
            }

            rules.Add(new PatchRule(
                id, Required(target, "browser"), Required(target, "module"),
                Required(target, "arch"), Required(target, "minVersion"),
                Required(target, "maxVersion"), Required(target, "section"),
                expectedMatches, pattern, writes, contextSha256));
        }
        return rules;
    }

    private static string Required(XElement element, string name) =>
        (string?)element.Attribute(name) is { Length: > 0 } value
            ? value
            : throw new FormatException($"Element '{element.Name}' is missing '{name}'.");

    private static void RejectUnknownAttributes(XElement element, HashSet<string> allowed) {
        XAttribute? unknown = element.Attributes().FirstOrDefault(attribute => !allowed.Contains(attribute.Name.LocalName));
        if (unknown is not null) {
            throw new FormatException($"Unknown attribute '{unknown.Name}' on '{element.Name}'.");
        }
    }

    private static int ParsePositiveInt(string text, string name) {
        int value = ParseNonNegativeInt(text, name);
        return value > 0 ? value : throw new FormatException($"{name} must be positive.");
    }

    private static int ParseNonNegativeInt(string text, string name) {
        NumberStyles style = NumberStyles.Integer;
        if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) {
            text = text[2..];
            style = NumberStyles.AllowHexSpecifier;
        }
        return int.TryParse(text, style, CultureInfo.InvariantCulture, out int value) && value >= 0
            ? value
            : throw new FormatException($"Invalid non-negative {name} '{text}'.");
    }

    private static byte[] ParseHexBytes(string text) {
        string compact = string.Concat(text.Where(character => !char.IsWhiteSpace(character)));
        try {
            return Convert.FromHexString(compact);
        } catch (FormatException exception) {
            throw new FormatException($"Invalid hex bytes '{text}'.", exception);
        }
    }
}
