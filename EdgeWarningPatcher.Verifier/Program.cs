using System.Text.Json;
using EdgeWarningPatcher.Verifier;

if (args.Length == 0 || args[0] is "-h" or "--help") {
    Console.WriteLine("Usage:");
    Console.WriteLine("  EdgeWarningPatcher.Verifier validate-rules --rules <patterns.xml>");
    Console.WriteLine("  EdgeWarningPatcher.Verifier verify --edge-application-path <path> --rules <patterns.xml> [--json]");
    return 0;
}

try {
    Dictionary<string, string?> options = ParseOptions(args.Skip(1));
    string rulesPath = Require(options, "--rules");
    IReadOnlyList<PatchRule> rules = RuleLoader.Load(rulesPath);
    if (args[0] == "validate-rules") {
        Console.WriteLine($"Validated {rules.Count} guarded patch rule(s).");
        return 0;
    }
    if (args[0] != "verify") {
        throw new ArgumentException($"Unknown command '{args[0]}'.");
    }

    string root = Path.GetFullPath(Require(options, "--edge-application-path"));
    (string version, string module) = FindLatestEdge(root);
    PatchRule[] candidates = rules.Where(candidate =>
        candidate.Browser.Equals("edge", StringComparison.OrdinalIgnoreCase) &&
        candidate.Module.Equals("msedge.dll", StringComparison.OrdinalIgnoreCase) &&
        VersionMatches(version, candidate.MinimumVersion, candidate.MaximumVersion)).ToArray();
    if (candidates.Length != 1) {
        throw new NotSupportedException(
            $"Expected exactly one guarded rule for Edge {version}, found {candidates.Length}. No files were modified.");
    }
    PatchRule rule = candidates[0];
    VerificationReport report = PatchVerifier.Verify(module, rule, "edge", version);
    if (options.ContainsKey("--json")) {
        Console.WriteLine(JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
    } else {
        Console.WriteLine($"Rule: {report.RuleId}");
        Console.WriteLine($"Module: {report.Module}");
        Console.WriteLine($"SHA-256: {report.ModuleSha256}");
        Console.WriteLine($"Matches: {report.MatchCount}");
        Console.WriteLine($"RVA: {(report.MatchRva is int rva ? $"0x{rva:X}" : "n/a")}");
        Console.WriteLine($"File offset: {(report.MatchFileOffset is long offset ? $"0x{offset:X}" : "n/a")}");
        Console.WriteLine($"Result: {(report.Passed ? "PASS" : "FAIL")} - {report.Reason}");
    }
    return report.Passed ? 0 : 1;
} catch (Exception exception) {
    Console.Error.WriteLine($"Error: {exception.Message}");
    return 2;
}

static Dictionary<string, string?> ParseOptions(IEnumerable<string> values) {
    string[] tokens = values.ToArray();
    Dictionary<string, string?> result = new(StringComparer.Ordinal);
    for (int i = 0; i < tokens.Length; i++) {
        string token = tokens[i];
        if (!token.StartsWith("--", StringComparison.Ordinal)) {
            throw new ArgumentException($"Unexpected argument '{token}'.");
        }
        if (token == "--json") {
            result[token] = null;
            continue;
        }
        if (++i >= tokens.Length) {
            throw new ArgumentException($"Option '{token}' requires a value.");
        }
        result[token] = tokens[i];
    }
    return result;
}

static string Require(Dictionary<string, string?> options, string name) =>
    options.TryGetValue(name, out string? value) && !string.IsNullOrWhiteSpace(value)
        ? value
        : throw new ArgumentException($"Missing required option '{name}'.");

static (string Version, string Module) FindLatestEdge(string root) {
    if (!Directory.Exists(root)) {
        throw new DirectoryNotFoundException($"Edge application path not found: {root}");
    }
    var candidate = Directory.EnumerateDirectories(root)
        .Select(path => (Path: path, Name: Path.GetFileName(path)))
        .Where(item => Version.TryParse(item.Name, out _))
        .OrderByDescending(item => Version.Parse(item.Name))
        .FirstOrDefault(item => File.Exists(Path.Combine(item.Path, "msedge.dll")));
    if (candidate == default) {
        throw new FileNotFoundException("No versioned msedge.dll was found.");
    }
    return (candidate.Name, Path.Combine(candidate.Path, "msedge.dll"));
}

static bool VersionMatches(string actualText, string minimumText, string maximumText) {
    if (!Version.TryParse(actualText, out Version? actual) ||
        !Version.TryParse(minimumText, out Version? minimum) || actual < minimum) {
        return false;
    }
    if (maximumText == "*") {
        return true;
    }
    if (maximumText.EndsWith(".*", StringComparison.Ordinal)) {
        return int.TryParse(maximumText[..^2], out int major) && actual.Major == major;
    }
    return Version.TryParse(maximumText, out Version? maximum) && actual <= maximum;
}
