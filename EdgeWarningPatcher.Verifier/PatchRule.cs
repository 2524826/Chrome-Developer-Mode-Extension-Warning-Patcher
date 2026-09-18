using System;
using System.Collections.Generic;

namespace EdgeWarningPatcher.Verifier;

public sealed record PatchWrite(int Offset, byte[] Expected, byte[] Replacement);

public sealed record PatchRule(
    string Id,
    string Browser,
    string Module,
    string Architecture,
    string MinimumVersion,
    string MaximumVersion,
    string Section,
    int ExpectedMatches,
    AobPattern Pattern,
    IReadOnlyList<PatchWrite> Writes,
    string? ContextSha256 = null);

public sealed record PlannedWrite(long FileOffset, int Rva, string ExpectedHex, string ReplacementHex);

public sealed record VerificationReport(
    bool Passed,
    string RuleId,
    string Browser,
    string Version,
    string Module,
    string ModuleSha256,
    string Section,
    int MatchCount,
    int? MatchRva,
    long? MatchFileOffset,
    IReadOnlyList<PlannedWrite> Writes,
    string Reason) {
    public DateTimeOffset TimestampUtc { get; init; } = DateTimeOffset.UtcNow;
    public string Severity => this.Passed ? "info" : "error";
    public string Operation => "dry-run-verify";
    public string PreconditionResult => this.Passed ? "passed" : "failed";
    public string BackupResult => "not-applicable; browser module is opened read-only";
    public string WriteResult => "not-attempted";
    public string VerificationResult => this.Passed ? "passed" : "failed";
    public string RollbackResult => "not-required";
}
