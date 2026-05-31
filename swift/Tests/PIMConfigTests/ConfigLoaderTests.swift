import Foundation
import Testing
@testable import PIMConfig

@Suite("ConfigLoader")
struct ConfigLoaderTests {

    // MARK: - Base config loading

    @Test("Default config when no file exists")
    func testDefaultConfigWhenNoFile() {
        // ConfigLoader.loadBaseConfig() returns all-access defaults when file is missing
        // We test the default PIMConfiguration struct directly
        let config = PIMConfiguration()
        #expect(config.calendars.enabled == true)
        #expect(config.calendars.mode == .all)
        #expect(config.calendars.items.isEmpty)
        #expect(config.reminders.enabled == true)
        #expect(config.reminders.mode == .all)
        #expect(config.contacts.enabled == true)
        #expect(config.mail.enabled == true)
        #expect(config.defaultCalendar == nil)
        #expect(config.defaultReminderList == nil)
    }

    // MARK: - JSON round-trip

    @Test("Config encodes and decodes correctly")
    func testConfigRoundTrip() throws {
        let config = PIMConfiguration(
            calendars: DomainFilterConfig(enabled: true, mode: .allowlist, items: ["Personal", "Family"]),
            reminders: DomainFilterConfig(enabled: true, mode: .blocklist, items: ["Spam"]),
            contacts: DomainFilterConfig(enabled: false),
            mail: DomainConfig(enabled: true),
            defaultCalendar: "Personal",
            defaultReminderList: "Reminders"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(PIMConfiguration.self, from: data)

        #expect(decoded == config)
    }

    @Test("SMTP tls_mode and IMAP block round-trip with snake_case keys")
    func testSMTPAndIMAPRoundTrip() throws {
        let config = PIMConfiguration(
            smtp: SMTPDefaults(
                host: "smtp.example.com", port: 587,
                username: "me@example.com", secretKey: "smtp.example.password",
                tlsMode: "starttls"
            ),
            imap: IMAPDefaults(
                host: "imap.mail.me.com", port: 993,
                username: "me@icloud.com", secretKey: "imap.icloud.password",
                sentFolder: "Sent Messages", appendSent: true
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(PIMConfiguration.self, from: data)
        #expect(decoded == config)

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let smtp = json["smtp"] as! [String: Any]
        #expect(smtp["tls_mode"] as? String == "starttls")
        #expect(smtp["secret_key"] as? String == "smtp.example.password")
        let imap = json["imap"] as! [String: Any]
        #expect(imap["sent_folder"] as? String == "Sent Messages")
        #expect(imap["append_sent"] as? Bool == true)
        #expect(imap["secret_key"] as? String == "imap.icloud.password")
    }

    @Test("Config uses snake_case JSON keys")
    func testSnakeCaseKeys() throws {
        let config = PIMConfiguration(
            defaultCalendar: "Work",
            defaultReminderList: "Tasks"
        )

        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["default_calendar"] as? String == "Work")
        #expect(json["default_reminder_list"] as? String == "Tasks")
        // Verify camelCase keys are NOT present
        #expect(json["defaultCalendar"] == nil)
        #expect(json["defaultReminderList"] == nil)
    }

    // MARK: - Profile merging

    @Test("Profile override replaces entire domain section")
    func testProfileMergeReplacesEntireDomain() {
        let base = PIMConfiguration(
            calendars: DomainFilterConfig(enabled: true, mode: .allowlist, items: ["A", "B", "C"]),
            reminders: DomainFilterConfig(enabled: true, mode: .allowlist, items: ["X", "Y"]),
            defaultCalendar: "A",
            defaultReminderList: "X"
        )

        let profile = PIMProfileOverride(
            calendars: DomainFilterConfig(enabled: true, mode: .allowlist, items: ["B"]),
            defaultCalendar: "B"
        )

        let merged = ConfigLoader.merge(base: base, profile: profile)

        // Calendars fully replaced by profile
        #expect(merged.calendars.items == ["B"])
        #expect(merged.defaultCalendar == "B")

        // Reminders inherited from base (not in profile)
        #expect(merged.reminders.items == ["X", "Y"])
        #expect(merged.defaultReminderList == "X")
    }

    @Test("Nil profile returns base unchanged")
    func testNilProfileReturnsBase() {
        let base = PIMConfiguration(
            calendars: DomainFilterConfig(enabled: true, mode: .allowlist, items: ["Personal"]),
            defaultCalendar: "Personal"
        )

        let merged = ConfigLoader.merge(base: base, profile: nil)
        #expect(merged == base)
    }

    @Test("Profile with no overrides returns base unchanged")
    func testEmptyProfileReturnsBase() {
        let base = PIMConfiguration(
            calendars: DomainFilterConfig(enabled: true, mode: .allowlist, items: ["Personal"]),
            defaultCalendar: "Personal"
        )

        let profile = PIMProfileOverride()
        let merged = ConfigLoader.merge(base: base, profile: profile)
        #expect(merged == base)
    }

    @Test("Profile can disable a domain")
    func testProfileDisablesDomain() {
        let base = PIMConfiguration(
            mail: DomainConfig(enabled: true)
        )

        let profile = PIMProfileOverride(
            mail: DomainConfig(enabled: false)
        )

        let merged = ConfigLoader.merge(base: base, profile: profile)
        #expect(merged.mail.enabled == false)
    }

    // MARK: - Profile JSON round-trip

    @Test("Profile encodes and decodes correctly")
    func testProfileRoundTrip() throws {
        let profile = PIMProfileOverride(
            calendars: DomainFilterConfig(enabled: true, mode: .allowlist, items: ["Family"]),
            defaultCalendar: "Family"
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PIMProfileOverride.self, from: data)
        #expect(decoded == profile)
    }

    // MARK: - Profile name validation

    @Test("Valid profile names are accepted")
    func testValidProfileNames() throws {
        try ConfigLoader.validateProfileName("default")
        try ConfigLoader.validateProfileName("agent-1")
        try ConfigLoader.validateProfileName("my_profile")
    }

    @Test("Path traversal in profile name is rejected")
    func testPathTraversalRejected() {
        #expect(throws: ConfigError.self) {
            try ConfigLoader.validateProfileName("../../etc/passwd")
        }
        #expect(throws: ConfigError.self) {
            try ConfigLoader.validateProfileName("foo/bar")
        }
        #expect(throws: ConfigError.self) {
            try ConfigLoader.validateProfileName("foo\\bar")
        }
    }

    @Test("Hidden file profile names are rejected")
    func testHiddenFileNamesRejected() {
        #expect(throws: ConfigError.self) {
            try ConfigLoader.validateProfileName(".hidden")
        }
    }

    @Test("Empty profile name is rejected")
    func testEmptyProfileNameRejected() {
        #expect(throws: ConfigError.self) {
            try ConfigLoader.validateProfileName("")
        }
    }

    @Test("profilePath strips path components as defense-in-depth")
    func testProfilePathStripsPathComponents() {
        // Even without validation, profilePath uses lastPathComponent
        let path = ConfigLoader.profilePath(for: "../../evil")
        #expect(path.lastPathComponent == "evil.json")
        #expect(!path.path.contains("../../"))
    }

    @Test("Profile with only some fields omits others in JSON")
    func testProfilePartialEncoding() throws {
        let profile = PIMProfileOverride(
            calendars: DomainFilterConfig(enabled: true, mode: .allowlist, items: ["Family"])
        )

        let data = try JSONEncoder().encode(profile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // calendars should be present
        #expect(json["calendars"] != nil)
        // reminders should NOT be present (nil in profile)
        #expect(json["reminders"] == nil)
    }
}

// MARK: - Environment-mutating tests (serialized to avoid data races)

@Suite("ConfigLoader - env isolation", .serialized)
struct ConfigLoaderEnvTests {

    @Test("APPLE_PIM_CONFIG_DIR overrides default config directory")
    func testConfigDirEnvOverride() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a config with contacts disabled so we can detect it was loaded
        let config = PIMConfiguration(
            contacts: DomainFilterConfig(enabled: false)
        )
        let data = try JSONEncoder().encode(config)
        try data.write(to: tmpDir.appendingPathComponent("config.json"))

        // setenv so ConfigLoader picks it up
        setenv("APPLE_PIM_CONFIG_DIR", tmpDir.path, 1)
        defer { unsetenv("APPLE_PIM_CONFIG_DIR") }

        #expect(ConfigLoader.configDir.path == tmpDir.path)
        #expect(ConfigLoader.defaultConfigPath.path == tmpDir.appendingPathComponent("config.json").path)
        #expect(ConfigLoader.profilesDir.path == tmpDir.appendingPathComponent("profiles").path)

        let loaded = ConfigLoader.loadBaseConfig()
        #expect(loaded.contacts.enabled == false)
    }

    @Test("loadProfile returns nil when profile file does not exist")
    func testLoadProfileReturnsNilForMissing() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        setenv("APPLE_PIM_CONFIG_DIR", tmpDir.path, 1)
        defer { unsetenv("APPLE_PIM_CONFIG_DIR") }

        // No profiles directory exists, so loadProfile should return nil
        // Note: the exit(1) behavior in load(profile:) for missing profiles
        // requires subprocess testing and is not covered here.
        let result = ConfigLoader.loadProfile(named: "nonexistent")
        #expect(result == nil)
    }
}
