import Foundation

/// Root configuration for the Apple PIM plugin.
/// Loaded from `~/.config/apple-pim/config.json`.
public struct PIMConfiguration: Codable, Equatable, Sendable {
    public var calendars: DomainFilterConfig
    public var reminders: DomainFilterConfig
    public var contacts: DomainFilterConfig
    public var mail: DomainConfig
    public var defaultCalendar: String?
    public var defaultReminderList: String?
    public var smtp: SMTPDefaults?
    public var imap: IMAPDefaults?

    public init(
        calendars: DomainFilterConfig = DomainFilterConfig(),
        reminders: DomainFilterConfig = DomainFilterConfig(),
        contacts: DomainFilterConfig = DomainFilterConfig(),
        mail: DomainConfig = DomainConfig(),
        defaultCalendar: String? = nil,
        defaultReminderList: String? = nil,
        smtp: SMTPDefaults? = nil,
        imap: IMAPDefaults? = nil
    ) {
        self.calendars = calendars
        self.reminders = reminders
        self.contacts = contacts
        self.mail = mail
        self.defaultCalendar = defaultCalendar
        self.defaultReminderList = defaultReminderList
        self.smtp = smtp
        self.imap = imap
    }

    enum CodingKeys: String, CodingKey {
        case calendars, reminders, contacts, mail, smtp, imap
        case defaultCalendar = "default_calendar"
        case defaultReminderList = "default_reminder_list"
    }
}

/// Non-secret SMTP connection defaults.
/// The password lives in `SecretsStore` under the key at `secretKey` (default `smtp.icloud.password`).
public struct SMTPDefaults: Codable, Equatable, Sendable {
    public var host: String?
    public var port: Int?
    public var username: String?
    public var secretKey: String?
    /// TLS transport mode: `"implicit"` (port 465, default) or `"starttls"` (port 587).
    public var tlsMode: String?

    public init(
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        secretKey: String? = nil,
        tlsMode: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.secretKey = secretKey
        self.tlsMode = tlsMode
    }

    enum CodingKeys: String, CodingKey {
        case host, port, username
        case secretKey = "secret_key"
        case tlsMode = "tls_mode"
    }
}

/// Non-secret IMAP connection defaults, used to APPEND SMTP-sent messages to the
/// Sent folder (see issue #63). The password lives in `SecretsStore` under
/// `secretKey`; if omitted, callers fall back to the SMTP password (iCloud uses
/// the same app-specific password for both).
public struct IMAPDefaults: Codable, Equatable, Sendable {
    public var host: String?
    public var port: Int?
    public var username: String?
    public var secretKey: String?
    /// Mailbox to APPEND into. iCloud: `"Sent Messages"`, Gmail: `"[Gmail]/Sent Mail"`,
    /// generic: `"Sent"`.
    public var sentFolder: String?
    /// When set, overrides the host-based default for whether APPEND runs.
    public var appendSent: Bool?

    public init(
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        secretKey: String? = nil,
        sentFolder: String? = nil,
        appendSent: Bool? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.secretKey = secretKey
        self.sentFolder = sentFolder
        self.appendSent = appendSent
    }

    enum CodingKeys: String, CodingKey {
        case host, port, username
        case secretKey = "secret_key"
        case sentFolder = "sent_folder"
        case appendSent = "append_sent"
    }
}

/// Configuration for a domain that supports item-level filtering (calendars, reminders, contacts).
public struct DomainFilterConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mode: FilterMode
    public var items: [String]

    public init(enabled: Bool = true, mode: FilterMode = .all, items: [String] = []) {
        self.enabled = enabled
        self.mode = mode
        self.items = items
    }
}

/// Configuration for a domain with only an enabled flag (mail).
public struct DomainConfig: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}

/// Filter mode for a domain's item list.
public enum FilterMode: String, Codable, Equatable, Sendable {
    case all
    case allowlist
    case blocklist
}
