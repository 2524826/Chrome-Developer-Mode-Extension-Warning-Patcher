using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace EdgeWarningPatcher.Verifier;

public sealed class AobPattern {
    private readonly byte[] bytes;
    private readonly bool[] significant;

    private AobPattern(byte[] bytes, bool[] significant) {
        this.bytes = bytes;
        this.significant = significant;
    }

    public int Length => this.bytes.Length;

    public byte[] ToLegacyWildcardBytes(byte wildcard = 0xFF) {
        byte[] result = new byte[this.bytes.Length];
        for (int index = 0; index < result.Length; index++) {
            if (this.significant[index] && this.bytes[index] == wildcard) {
                throw new InvalidOperationException(
                    $"Pattern contains a literal {wildcard:X2} byte that cannot be represented by the native wildcard format.");
            }
            result[index] = this.significant[index] ? this.bytes[index] : wildcard;
        }
        return result;
    }

    public static AobPattern Parse(string value) {
        string[] tokens = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0) {
            throw new FormatException("BytePattern must not be empty.");
        }

        byte[] bytes = new byte[tokens.Length];
        bool[] significant = new bool[tokens.Length];
        for (int i = 0; i < tokens.Length; i++) {
            if (tokens[i] is "?" or "??") {
                continue;
            }

            if (tokens[i].Length != 2 ||
                !byte.TryParse(tokens[i], NumberStyles.AllowHexSpecifier,
                    CultureInfo.InvariantCulture, out bytes[i])) {
                throw new FormatException($"Invalid BytePattern token '{tokens[i]}'.");
            }
            significant[i] = true;
        }

        if (!significant.Any(value => value)) {
            throw new FormatException("BytePattern cannot consist only of wildcards.");
        }
        return new AobPattern(bytes, significant);
    }

    public IReadOnlyList<int> FindAll(ReadOnlySpan<byte> data) {
        List<int> matches = new();
        if (data.Length < this.bytes.Length) {
            return matches;
        }

        for (int start = 0; start <= data.Length - this.bytes.Length; start++) {
            bool matched = true;
            for (int index = 0; index < this.bytes.Length; index++) {
                if (this.significant[index] && data[start + index] != this.bytes[index]) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                matches.Add(start);
            }
        }
        return matches;
    }
}
