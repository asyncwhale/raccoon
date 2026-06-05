import Foundation

// MARK: - SecretScan

/// Pure, testable secret detection for clipboard payloads (§9.5 hardening).
///
/// The three FEED actions copy record content verbatim to the general pasteboard. A session
/// can contain API keys, tokens, or private keys pasted by the user; copying those to the
/// general pasteboard risks leaking them to clipboard history / Universal Clipboard. This
/// scanner is a *conservative* detector run at the copy site so the UI can warn before the
/// secret hits the clipboard.
///
/// Design goals:
/// - **Pure & deterministic** — `scan(_:)` is a function of its input only, so the exact hits
///   can be asserted headlessly in Core tests. No I/O, no network, no logging of values.
/// - **Conservative** — patterns require realistic length floors and (for the generic
///   key/secret/token case) an *assigned literal value*, so ordinary prose and code like
///   `let token = computeToken()` does NOT trip. We accept misses over false alarms.
/// - **Never echoes secrets** — `SecretHit` carries only a `kind` and the matched character
///   `range`; it never stores the secret text, so it is safe to log.
public enum SecretScan {

    /// The class of secret a hit matched. `description` is a short, value-free label safe to
    /// surface in UI / logs.
    public enum Kind: String, Sendable, CaseIterable, Equatable {
        case awsAccessKey      // AKIA + 16 uppercase alnum
        case openAIKey         // sk-XXXXXXXXXXXXXXXXXXXX (>=20)
        case githubToken       // ghp_/gho_/ghu_/ghs_/ghr_ + 20+ alnum
        case slackToken        // xoxb-/xoxa-/xoxp-/xoxr-/xoxs- + 10+
        case pemPrivateKey     // -----BEGIN ... PRIVATE KEY-----
        case genericSecret     // api_key/secret/token/password/bearer = "literal"

        /// Human-readable, value-free description (safe for logs / toasts).
        public var description: String {
            switch self {
            case .awsAccessKey:  return "AWS access key"
            case .openAIKey:     return "OpenAI-style key"
            case .githubToken:   return "GitHub token"
            case .slackToken:    return "Slack token"
            case .pemPrivateKey: return "PEM private key"
            case .genericSecret: return "generic secret assignment"
            }
        }
    }

    /// A single detected secret: its `kind` plus the `range` (in UTF-16 offsets, matching
    /// `NSRange`) of the match within the scanned string. The secret value itself is never
    /// retained, so a `SecretHit` is safe to log or surface in the UI.
    public struct SecretHit: Sendable, Equatable {
        public let kind: Kind
        public let range: Range<Int>

        public init(kind: Kind, range: Range<Int>) {
            self.kind = kind
            self.range = range
        }
    }

    // MARK: Patterns

    /// (kind, pattern, options). Order is stable so results sort deterministically.
    private struct Rule {
        let kind: Kind
        let regex: NSRegularExpression
    }

    private static let rules: [Rule] = {
        // Helper to build a rule; patterns are static & known-valid, so a force-unwrap here
        // would only fail at first-run if a literal were mistyped (caught immediately by tests).
        func make(_ kind: Kind, _ pattern: String, _ options: NSRegularExpression.Options = []) -> Rule? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return Rule(kind: kind, regex: re)
        }
        return [
            // AWS access key id — case-sensitive, exactly 16 uppercase alnum after AKIA.
            make(.awsAccessKey, #"AKIA[0-9A-Z]{16}"#),
            // OpenAI-style — sk- followed by >=20 base62 chars.
            make(.openAIKey, #"sk-[A-Za-z0-9]{20,}"#),
            // GitHub — ghp_/gho_/ghu_/ghs_/ghr_ + >=20 base62.
            make(.githubToken, #"gh[pousr]_[A-Za-z0-9]{20,}"#),
            // Slack — xoxb/a/p/r/s- + >=10 of base62 + hyphen.
            make(.slackToken, #"xox[baprs]-[A-Za-z0-9-]{10,}"#),
            // PEM private key header.
            make(.pemPrivateKey, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
            // Generic assignment: (api_key|secret|token|password|passwd|bearer) [:=] <value> (>=6).
            // This locates *candidate* assignments per the spec pattern; the assigned value
            // (capture group 2) is then validated by `looksLikeSecretValue(_:)` so that ordinary
            // code such as `let token = computeToken()` or `var apiKey: String? = nil` — which
            // assign a *call expression* or a keyword, not a secret literal — does NOT trip.
            make(.genericSecret,
                 #"(?i)(api[_-]?key|secret|token|password|passwd|bearer)\s*[:=]\s*(\S{6,})"#),
        ].compactMap { $0 }
    }()

    /// Decide whether the captured RHS of a generic `key = value` assignment looks like an
    /// actual secret literal rather than ordinary code. Conservative: we *reject* values that
    /// look like a function call, a type annotation, or a common non-secret keyword.
    ///
    /// Rejected (NOT secrets):
    /// - contains `(` or `)` → a call expression, e.g. `computeToken()`, `obtainSecret()`
    /// - bare `nil` / `null` / `true` / `false` / `none` (case-insensitive)
    ///
    /// Accepted (likely secret): quoted strings and contiguous opaque tokens like
    /// `s3cr3tvalue`, `hunter2hunter`, `ghp_xxxx…`, `correct-horse`.
    private static func looksLikeSecretValue(_ raw: String) -> Bool {
        // Strip surrounding quotes for the keyword check (a quoted "nil" is still not a secret,
        // but in practice nobody quotes those as a secret; treat unquoted keywords as code).
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if trimmed.isEmpty { return false }
        // Call expression / parenthesised RHS → it's code, not a literal secret.
        if raw.contains("(") || raw.contains(")") { return false }
        // Type-annotation syntax → e.g. `apiKey: String? = nil` captures `String?`. Optionals,
        // generics, and trailing-colon forms are code, not secret literals.
        if raw.contains("?") || raw.contains("<") || raw.contains(">") { return false }
        // Common non-secret keywords assigned to these names in ordinary code.
        let codeKeywords: Set<String> = ["nil", "null", "none", "true", "false", "undefined"]
        if codeKeywords.contains(trimmed.lowercased()) { return false }
        // After trimming quotes the value must still clear the length floor.
        return trimmed.count >= 6
    }

    // MARK: API

    /// Scan `text` for likely secrets. Returns one `SecretHit` per non-overlapping match,
    /// sorted by start offset (then by rule order). Conservative by construction: length
    /// floors and the generic-assignment requirement keep ordinary prose/code from tripping.
    ///
    /// Pure: depends only on `text`. Never logs or retains secret values.
    public static func scan(_ text: String) -> [SecretHit] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hits: [SecretHit] = []
        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let m = match, m.range.location != NSNotFound else { return }
                // The generic key=value rule is fuzzy: validate the captured RHS (group 2) so
                // call expressions / keyword assignments in ordinary code don't false-positive.
                if rule.kind == .genericSecret {
                    let valueRange = m.range(at: 2)
                    guard valueRange.location != NSNotFound,
                          looksLikeSecretValue(ns.substring(with: valueRange)) else { return }
                }
                let lower = m.range.location
                let upper = m.range.location + m.range.length
                hits.append(SecretHit(kind: rule.kind, range: lower..<upper))
            }
        }
        return hits.sorted { ($0.range.lowerBound, $0.kind.rawValue) < ($1.range.lowerBound, $1.kind.rawValue) }
    }

    /// Convenience: the set of distinct `Kind`s present in `text` (value-free; safe to log).
    public static func kinds(in text: String) -> Set<Kind> {
        Set(scan(text).map(\.kind))
    }

    /// Convenience: number of secret hits in `text`.
    public static func count(in text: String) -> Int {
        scan(text).count
    }
}
