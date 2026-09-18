using System.Security.Cryptography;
using System.Text;
using EdgeWarningPatcher.Verifier;

List<(string Name, Action Test)> tests = new() {
    ("AOB wildcard does not treat literal FF as wildcard", TestLiteralFf),
    ("native wildcard serialization rejects ambiguous literal FF", TestNativeWildcardSerialization),
    ("guarded rules schema loads the Edge 151 rule", TestRepositoryRules),
    ("strict schema rejects unknown attributes", TestUnknownAttribute),
    ("strict schema rejects non-unique match policy", TestNonUniquePolicy),
    ("strict schema rejects overlapping writes", TestOverlappingWrites),
    ("unique match passes all gates", TestUniqueMatch),
    ("zero matches fails closed", TestZeroMatches),
    ("multiple matches fail closed", TestMultipleMatches),
    ("section-boundary write fails closed", TestSectionBoundary),
    ("unexpected original byte fails closed", TestOriginalMismatch),
    ("already-patched byte fails closed", TestAlreadyPatched),
    ("context hash mismatch fails closed", TestContextHashMismatch),
    ("wrong architecture fails closed", TestWrongArchitecture),
    ("older version fails before scanning", TestVersionMismatch),
    ("future version remains eligible while the rule matches", TestFutureVersion),
    ("browser mismatch fails before scanning", TestBrowserMismatch),
    ("dry-run never changes the fixture", TestDryRunDoesNotWrite)
};

int failed = 0;
foreach ((string name, Action test) in tests) {
    try {
        test();
        Console.WriteLine($"PASS {name}");
    } catch (Exception exception) {
        failed++;
        Console.Error.WriteLine($"FAIL {name}: {exception.Message}");
    }
}
Console.WriteLine($"{tests.Count - failed}/{tests.Count} tests passed.");
return failed == 0 ? 0 : 1;

static void TestLiteralFf() {
    AobPattern pattern = AobPattern.Parse("AA ?? FF CC");
    Equal(1, pattern.FindAll(new byte[] { 0xAA, 0x10, 0xFF, 0xCC }).Count, "literal FF should match FF");
    Equal(0, pattern.FindAll(new byte[] { 0xAA, 0x10, 0x22, 0xCC }).Count, "literal FF must not match another byte");
}

static void TestNativeWildcardSerialization() {
    byte[] serialized = AobPattern.Parse("AA ?? CC").ToLegacyWildcardBytes();
    True(serialized.SequenceEqual(new byte[] { 0xAA, 0xFF, 0xCC }), "wildcard encoding changed");
    Throws<InvalidOperationException>(() => AobPattern.Parse("AA FF CC").ToLegacyWildcardBytes(),
        "literal FF must not be serialized as a wildcard");
}

static void TestRepositoryRules() {
    string path = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "patterns.xml"));
    IReadOnlyList<PatchRule> rules = RuleLoader.Load(path);
    Equal(1, rules.Count, "repository should contain one guarded rule");
    Equal("edge-extension-warning-151-plus-x64", rules[0].Id, "wrong guarded rule id");
    Equal("*", rules[0].MaximumVersion, "forward-compatible rule should have no upper version bound");
}

static void TestUnknownAttribute() => WithXml(
    XmlTarget(" unexpected=\"true\"", "", ""),
    path => Throws<FormatException>(() => RuleLoader.Load(path), "unknown attribute must fail"));

static void TestNonUniquePolicy() => WithXml(
    XmlTarget("", " expectedMatches=\"2\"", ""),
    path => Throws<FormatException>(() => RuleLoader.Load(path), "expectedMatches other than one must fail"));

static void TestOverlappingWrites() => WithXml(
    XmlTarget("", "", "<Write offset=\"0x1\" expected=\"BB FF\" replacement=\"11 22\" />"),
    path => Throws<FormatException>(() => RuleLoader.Load(path), "overlapping writes must fail"));

static void TestUniqueMatch() => WithFixture(new[] { (0x30, new byte[] { 0xAA, 0xBB, 0xFF, 0xCC }) }, PeImage.MachineAmd64, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "151.0.4129.59");
    True(report.Passed, report.Reason);
    Equal(1, report.MatchCount, "unique match count");
    Equal(0x1030, report.MatchRva, "match RVA");
    Equal(0x231L, report.Writes.Single().FileOffset, "planned file offset");
});

static void TestZeroMatches() => WithFixture(Array.Empty<(int, byte[])>(), PeImage.MachineAmd64, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "151.0.4129.59");
    False(report.Passed, "zero matches must fail");
    Equal(0, report.MatchCount, "zero match count");
});

static void TestMultipleMatches() => WithFixture(new[] {
    (0x30, new byte[] { 0xAA, 0xBB, 0xFF, 0xCC }),
    (0x50, new byte[] { 0xAA, 0x11, 0xFF, 0xCC })
}, PeImage.MachineAmd64, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "151.0.4129.59");
    False(report.Passed, "multiple matches must fail");
    Equal(2, report.MatchCount, "multiple match count");
});

static void TestSectionBoundary() => WithFixture(new[] {
    (0x1FC, new byte[] { 0xAA, 0xBB, 0xFF, 0xCC })
}, PeImage.MachineAmd64, path => {
    PatchRule rule = Rule(new PatchWrite(3, new byte[] { 0xCC, 0x00 }, new byte[] { 0x01, 0x02 }));
    VerificationReport report = PatchVerifier.Verify(path, rule, "edge", "151.0.4129.59");
    False(report.Passed, "out-of-section write must fail");
    Contains("bounds", report.Reason, "boundary failure reason");
});

static void TestOriginalMismatch() => WithFixture(new[] {
    (0x30, new byte[] { 0xAA, 0x44, 0xFF, 0xCC })
}, PeImage.MachineAmd64, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "151.0.4129.59");
    False(report.Passed, "unexpected original must fail");
    Contains("original bytes differ", report.Reason, "original mismatch reason");
});

static void TestAlreadyPatched() => WithFixture(new[] {
    (0x30, new byte[] { 0xAA, 0xDD, 0xFF, 0xCC })
}, PeImage.MachineAmd64, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "151.0.4129.59");
    False(report.Passed, "already-patched input must fail");
    Contains("already patched", report.Reason, "already-patched reason");
});

static void TestContextHashMismatch() => WithFixture(new[] {
    (0x30, new byte[] { 0xAA, 0xBB, 0xFF, 0xCC })
}, PeImage.MachineAmd64, path => {
    PatchRule rule = Rule(contextSha256: new string('0', 64));
    VerificationReport report = PatchVerifier.Verify(path, rule, "edge", "151.0.4129.59");
    False(report.Passed, "wrong context hash must fail");
    Contains("context SHA-256", report.Reason, "context hash reason");
});

static void TestWrongArchitecture() => WithFixture(new[] {
    (0x30, new byte[] { 0xAA, 0xBB, 0xFF, 0xCC })
}, 0x014C, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "151.0.4129.59");
    False(report.Passed, "x86 image must fail");
    Contains("not an x64", report.Reason, "architecture reason");
});

static void TestVersionMismatch() => WithFixture(Array.Empty<(int, byte[])>(), PeImage.MachineAmd64, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "150.0.4000.0");
    False(report.Passed, "older version must fail");
    Contains("outside", report.Reason, "version reason");
});

static void TestFutureVersion() => WithFixture(new[] {
    (0x30, new byte[] { 0xAA, 0xBB, 0xFF, 0xCC })
}, PeImage.MachineAmd64, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "152.1.5000.7");
    True(report.Passed, report.Reason);
});

static void TestBrowserMismatch() => WithFixture(Array.Empty<(int, byte[])>(), PeImage.MachineAmd64, path => {
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "chrome", "151.0.4129.59");
    False(report.Passed, "wrong browser must fail");
    Contains("does not match", report.Reason, "browser reason");
});

static void TestDryRunDoesNotWrite() => WithFixture(new[] {
    (0x30, new byte[] { 0xAA, 0xBB, 0xFF, 0xCC })
}, PeImage.MachineAmd64, path => {
    string before = Hash(path);
    VerificationReport report = PatchVerifier.Verify(path, Rule(), "edge", "151.0.4129.59");
    string after = Hash(path);
    True(report.Passed, report.Reason);
    Equal(before, after, "dry-run changed the input file");
});

static PatchRule Rule(PatchWrite? write = null, string? contextSha256 = null) => new(
    "test-edge-rule", "edge", "msedge.dll", "x64", "151.0.0.0", "*",
    ".text", 1, AobPattern.Parse("AA ?? FF CC"),
    new[] { write ?? new PatchWrite(1, new byte[] { 0xBB }, new byte[] { 0xDD }) },
    contextSha256);

static string XmlTarget(string extraTargetAttribute, string expectedMatchesOverride, string extraWrite) {
    string match = expectedMatchesOverride.Length == 0 ? " expectedMatches=\"1\"" : expectedMatchesOverride;
    return $"""
        <Defaults>
          <PatchTargets schemaVersion="1">
            <PatchTarget id="rule" browser="edge" module="msedge.dll" arch="x64" minVersion="151.0.4129.59" maxVersion="151.0.4129.59" section=".text"{match}{extraTargetAttribute}>
              <BytePattern>AA ?? FF CC</BytePattern>
              <Write offset="0x1" expected="BB" replacement="DD" />
              {extraWrite}
            </PatchTarget>
          </PatchTargets>
        </Defaults>
        """;
}

static void WithXml(string xml, Action<string> action) {
    string path = Path.Combine(Path.GetTempPath(), $"edge-warning-rules-{Guid.NewGuid():N}.xml");
    File.WriteAllText(path, xml, Encoding.UTF8);
    try {
        action(path);
    } finally {
        File.Delete(path);
    }
}

static void WithFixture(IEnumerable<(int Offset, byte[] Bytes)> inserts, ushort machine,
    Action<string> action) {
    string root = Path.Combine(Path.GetTempPath(), $"edge-warning-fixture-{Guid.NewGuid():N}");
    Directory.CreateDirectory(root);
    string path = Path.Combine(root, "msedge.dll");
    byte[] image = new byte[0x400];
    WriteUInt16(image, 0x00, 0x5A4D);
    WriteUInt32(image, 0x3C, 0x80);
    WriteUInt32(image, 0x80, 0x00004550);
    WriteUInt16(image, 0x84, machine);
    WriteUInt16(image, 0x86, 1);
    WriteUInt16(image, 0x94, 0xF0);
    Encoding.ASCII.GetBytes(".text").CopyTo(image, 0x188);
    WriteUInt32(image, 0x190, 0x200);
    WriteUInt32(image, 0x194, 0x1000);
    WriteUInt32(image, 0x198, 0x200);
    WriteUInt32(image, 0x19C, 0x200);
    foreach ((int offset, byte[] bytes) in inserts) {
        bytes.CopyTo(image, 0x200 + offset);
    }
    File.WriteAllBytes(path, image);
    try {
        action(path);
    } finally {
        Directory.Delete(root, recursive: true);
    }
}

static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
static void WriteUInt16(byte[] data, int offset, ushort value) => BitConverter.GetBytes(value).CopyTo(data, offset);
static void WriteUInt32(byte[] data, int offset, uint value) => BitConverter.GetBytes(value).CopyTo(data, offset);
static void True(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
static void False(bool value, string message) => True(!value, message);
static void Equal<T>(T expected, T actual, string message) {
    if (!EqualityComparer<T>.Default.Equals(expected, actual)) {
        throw new InvalidOperationException($"{message}: expected {expected}, actual {actual}");
    }
}
static void Contains(string expected, string actual, string message) {
    if (!actual.Contains(expected, StringComparison.OrdinalIgnoreCase)) {
        throw new InvalidOperationException($"{message}: '{actual}' does not contain '{expected}'");
    }
}
static void Throws<TException>(Action action, string message) where TException : Exception {
    try {
        action();
    } catch (TException) {
        return;
    }
    throw new InvalidOperationException(message);
}
