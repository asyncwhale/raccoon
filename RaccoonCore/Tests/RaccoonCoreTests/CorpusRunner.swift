import Foundation
@testable import RaccoonCore

/// Test infrastructure for the golden corpus.
///
/// The corpus is a set of paired files under `corpus/`:
///   `<name>.in.txt`        — dirty input, byte-exact (real ESC/BOM/box chars)
///   `<name>.expected.txt`  — expected cleaned output, plain UTF-8
///
/// These are wired into the test target as a `.copy` resource, so they are
/// readable at runtime via `Bundle.module`.
enum CorpusRunner {

    struct Case {
        let name: String
        let input: String
        let expected: String
    }

    /// Enumerate every `<name>.in.txt` in the `corpus` resource directory and
    /// pair it with its sibling `<name>.expected.txt`.
    ///
    /// Returns tuples sorted by name for deterministic iteration.
    static func corpusCases() -> [(name: String, input: String, expected: String)] {
        let inputURLs = Bundle.module.urls(
            forResourcesWithExtension: "txt",
            subdirectory: "corpus"
        ) ?? []

        var cases: [(name: String, input: String, expected: String)] = []

        for inURL in inputURLs where inURL.lastPathComponent.hasSuffix(".in.txt") {
            // name = filename with ".in.txt" removed.
            let file = inURL.lastPathComponent
            let name = String(file.dropLast(".in.txt".count))

            let expectedURL = inURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(name).expected.txt")

            guard
                let inputData = try? Data(contentsOf: inURL),
                let expectedData = try? Data(contentsOf: expectedURL),
                let input = String(data: inputData, encoding: .utf8),
                let expected = String(data: expectedData, encoding: .utf8)
            else {
                continue
            }

            cases.append((name: name, input: input, expected: expected))
        }

        return cases.sorted { $0.name < $1.name }
    }

    /// A simple line-by-line unified-style diff for mismatch messages.
    static func diff(name: String, expected: String, actual: String) -> String {
        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        let maxCount = max(expectedLines.count, actualLines.count)

        var out = "corpus mismatch [\(name)]\n--- expected\n+++ actual\n"
        for i in 0..<maxCount {
            let e = i < expectedLines.count ? expectedLines[i] : nil
            let a = i < actualLines.count ? actualLines[i] : nil
            if e == a {
                if let e { out += "  \(visible(e))\n" }
            } else {
                if let e { out += "- \(visible(e))\n" }
                if let a { out += "+ \(visible(a))\n" }
            }
        }
        return out
    }

    /// Make invisible characters visible in diff output.
    private static func visible(_ s: String) -> String {
        var r = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x09: r += "\\t"
            case 0x00..<0x20, 0x7F: r += String(format: "\\x%02X", scalar.value)
            case 0x00A0: r += "·NBSP·"
            case 0x200B: r += "·ZWSP·"
            case 0xFEFF: r += "·BOM·"
            default: r.unicodeScalars.append(scalar)
            }
        }
        return r
    }
}
