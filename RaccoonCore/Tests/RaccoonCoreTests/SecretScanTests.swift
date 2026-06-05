import Testing
import Foundation
@testable import RaccoonCore

/// Tests for `SecretScan` — the conservative secret detector run at the clipboard FEED site.
///
/// Two halves: (1) every supported pattern is detected, (2) ordinary prose/code does NOT
/// false-positive. The negative cases are the load-bearing ones — a scrubber that cries wolf
/// trains users to ignore it.
struct SecretScanTests {

    // MARK: Positive — each pattern is detected

    @Test("AWS access key id is detected")
    func detectsAWS() {
        let hits = SecretScan.scan("creds: AKIAIOSFODNN7EXAMPLE here")
        #expect(hits.contains { $0.kind == .awsAccessKey })
    }

    @Test("OpenAI-style sk- key is detected")
    func detectsOpenAI() {
        let hits = SecretScan.scan("use sk-abcdefghijklmnopqrstuvwx for auth")
        #expect(hits.contains { $0.kind == .openAIKey })
    }

    @Test("GitHub token variants are detected", arguments: [
        "ghp_0123456789abcdefghijABCD",
        "gho_0123456789abcdefghijABCD",
        "ghu_0123456789abcdefghijABCD",
        "ghs_0123456789abcdefghijABCD",
        "ghr_0123456789abcdefghijABCD",
    ])
    func detectsGitHub(token: String) {
        let hits = SecretScan.scan("token \(token) ok")
        #expect(hits.contains { $0.kind == .githubToken })
    }

    @Test("Slack token variants are detected", arguments: [
        "xoxb-1234567890-abcdefABCDEF",
        "xoxa-1234567890-abcdefABCDEF",
        "xoxp-1234567890-abcdefABCDEF",
        "xoxr-1234567890-abcdefABCDEF",
        "xoxs-1234567890-abcdefABCDEF",
    ])
    func detectsSlack(token: String) {
        let hits = SecretScan.scan("slack=\(token)")
        #expect(hits.contains { $0.kind == .slackToken })
    }

    @Test("PEM private key header is detected", arguments: [
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
    ])
    func detectsPEM(header: String) {
        let hits = SecretScan.scan("\(header)\nMIIE...\n")
        #expect(hits.contains { $0.kind == .pemPrivateKey })
    }

    @Test("Generic key=value assignment is detected", arguments: [
        "api_key = \"s3cr3tvalue\"",
        "api-key: hunter2hunter",
        "apikey=abcdef123456",
        "secret = topsecretvalue",
        "token = \"ghp_xxxxxxxxxxxxxxxxxxxx\"",
        "password: correct-horse",
        "passwd=batterystaple",
        "bearer: abc123def456",
    ])
    func detectsGenericAssignment(sample: String) {
        let hits = SecretScan.scan(sample)
        #expect(!hits.isEmpty)
    }

    // MARK: Negative — ordinary code/prose does NOT trip

    @Test("No assigned literal value does not trip generic rule")
    func noFalsePositiveOnComputedToken() {
        // The required-by-spec negative: a call expression, not an assigned secret literal.
        #expect(SecretScan.scan("let token = computeToken()").isEmpty)
    }

    @Test("Ordinary prose mentioning secrets does not trip", arguments: [
        "Please rotate your API key in the settings panel.",
        "The token expired, so the request failed.",
        "Enter your password to continue.",
        "We store the secret in the Keychain, never UserDefaults.",
        "This function returns a bearer of bad news.",
    ])
    func noFalsePositiveOnProse(sample: String) {
        #expect(SecretScan.scan(sample).isEmpty)
    }

    @Test("Ordinary code without literal secrets does not trip", arguments: [
        "func makeToken() -> String { fatalError() }",
        "let secret = obtainSecret()",
        "var apiKey: String? = nil",
        "if password.isEmpty { return }",
        "self.token = self.computeToken(from: input)",
    ])
    func noFalsePositiveOnCode(sample: String) {
        #expect(SecretScan.scan(sample).isEmpty)
    }

    @Test("Short literal value below floor does not trip generic rule")
    func noFalsePositiveOnShortValue() {
        // Floor is \S{6,}; a 3-char value must not match.
        #expect(SecretScan.scan("key = abc").isEmpty)
        #expect(SecretScan.scan("token = no").isEmpty)
    }

    @Test("Lowercase akia / short sk- prefixes do not trip")
    func noFalsePositiveOnNearMisses() {
        // AWS is case-sensitive uppercase; sk- needs >=20 chars.
        #expect(SecretScan.scan("akiaiosfodnn7example").isEmpty)
        #expect(SecretScan.scan("sk-short").isEmpty)
        #expect(SecretScan.scan("ghp_short").isEmpty)
    }

    @Test("Empty string yields no hits")
    func emptyIsEmpty() {
        #expect(SecretScan.scan("").isEmpty)
    }

    // MARK: API surface — count / kinds / hits never carry the value

    @Test("Multiple secrets are all counted")
    func countsMultiple() {
        let text = """
        AKIAIOSFODNN7EXAMPLE
        sk-abcdefghijklmnopqrstuvwx
        -----BEGIN PRIVATE KEY-----
        """
        #expect(SecretScan.count(in: text) >= 3)
        let kinds = SecretScan.kinds(in: text)
        #expect(kinds.contains(.awsAccessKey))
        #expect(kinds.contains(.openAIKey))
        #expect(kinds.contains(.pemPrivateKey))
    }

    @Test("Hits are sorted by start offset")
    func hitsSorted() {
        let text = "first sk-abcdefghijklmnopqrstuvwx then AKIAIOSFODNN7EXAMPLE"
        let hits = SecretScan.scan(text)
        #expect(hits == hits.sorted { $0.range.lowerBound < $1.range.lowerBound })
    }

    @Test("Hit ranges point at the actual secret span")
    func rangesAreAccurate() {
        let text = "x AKIAIOSFODNN7EXAMPLE y"
        let hits = SecretScan.scan(text)
        guard let aws = hits.first(where: { $0.kind == .awsAccessKey }) else {
            Issue.record("expected an AWS hit")
            return
        }
        let ns = text as NSString
        let matched = ns.substring(with: NSRange(location: aws.range.lowerBound,
                                                 length: aws.range.upperBound - aws.range.lowerBound))
        #expect(matched == "AKIAIOSFODNN7EXAMPLE")
    }
}
