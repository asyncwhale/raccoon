import Foundation
import Testing
@testable import RaccoonCore

/// Round-trip + back-compat coverage for the `menuBarMode` setting.
@Suite("Settings.menuBarMode")
struct SettingsMenuBarModeTests {

    /// `menuBarMode` defaults to `false` on the canonical default settings.
    @Test("defaults to false")
    func defaultsFalse() {
        #expect(Settings.default.menuBarMode == false)
    }

    /// `menuBarMode` survives a JSON encode/decode round-trip in both states.
    @Test("round-trips through JSON", arguments: [true, false])
    func roundTrips(_ value: Bool) throws {
        var settings = Settings.default
        settings.menuBarMode = value

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded.menuBarMode == value)
        #expect(decoded == settings)
    }

    /// Settings JSON written BEFORE `menuBarMode` existed (key absent) still
    /// decodes, defaulting the missing flag to `false` — back-compat via
    /// `decodeIfPresent(...) ?? false`.
    @Test("absent key decodes to false (back-compat)")
    func absentKeyDefaultsFalse() throws {
        // Encode a current Settings, then strip the menuBarMode key to simulate
        // an older settings.json.
        let data = try JSONEncoder().encode(Settings.default)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "menuBarMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Settings.self, from: legacyData)
        #expect(decoded.menuBarMode == false)
    }
}
