import Foundation

/// Formats config command output for human-readable display.
public struct ConfigFormatter {

    /// Format `config show` output as readable text.
    public static func formatConfigShow(
        config: PIMConfiguration,
        configPath: String,
        profilesDir: String,
        activeProfile: String?
    ) -> String {
        var lines: [String] = []

        lines.append("Apple PIM Configuration")
        lines.append("=======================")
        lines.append("")
        lines.append("Config path:    \(tildeContract(configPath))")
        lines.append("Profiles dir:   \(tildeContract(profilesDir))")
        lines.append("Active profile: \(activeProfile ?? "(none)")")
        lines.append("")

        // Calendars
        lines.append(domainFilterLine("Calendars", config.calendars))
        // Reminders
        lines.append(domainFilterLine("Reminders", config.reminders))
        if config.reminders.privateWrites {
            lines.append("  Private Reminders writes (flags, subtasks, sections, tags): on")
        }
        // Contacts
        lines.append(domainFilterLine("Contacts", config.contacts))
        // Mail
        lines.append(domainLine("Mail", config.mail))

        // Defaults
        if config.defaultCalendar != nil || config.defaultReminderList != nil {
            lines.append("")
            if let cal = config.defaultCalendar {
                lines.append("Default calendar:      \(cal)")
            }
            if let rem = config.defaultReminderList {
                lines.append("Default reminder list: \(rem)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Format `config init` output as readable text.
    public static func formatConfigInit(
        configPath: String,
        profilesDir: String,
        calendars: [[String: Any]]? = nil,
        reminderLists: [[String: Any]],
        defaultCalendar: String? = nil,
        defaultReminderList: String
    ) -> String {
        var lines: [String] = []

        if let calendars, !calendars.isEmpty {
            lines.append("Available Calendars")
            lines.append("-------------------")
            for cal in calendars {
                let title = cal["title"] as? String ?? "Unknown"
                let type = cal["type"] as? String ?? ""
                let source = cal["source"] as? String ?? ""
                let detail = [type, source].filter { !$0.isEmpty }.joined(separator: ", ")
                lines.append("  \(title.padding(toLength: 24, withPad: " ", startingAt: 0))(\(detail))")
            }
            lines.append("")
        }

        if !reminderLists.isEmpty {
            lines.append("Available Reminder Lists")
            lines.append("------------------------")
            for list in reminderLists {
                let title = list["title"] as? String ?? "Unknown"
                let source = list["source"] as? String ?? ""
                lines.append("  \(title.padding(toLength: 24, withPad: " ", startingAt: 0))(\(source))")
            }
            lines.append("")
        }

        // Defaults
        let hasDefaultCal = defaultCalendar != nil && !defaultCalendar!.isEmpty
        let hasDefaultRem = !defaultReminderList.isEmpty
        if hasDefaultCal || hasDefaultRem {
            lines.append("Defaults:")
            if let cal = defaultCalendar, !cal.isEmpty {
                lines.append("  Calendar:       \(cal)")
            }
            if hasDefaultRem {
                lines.append("  Reminder list:  \(defaultReminderList)")
            }
            lines.append("")
        }

        lines.append("Config path:  \(tildeContract(configPath))")
        lines.append("Profiles dir: \(tildeContract(profilesDir))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private static func domainFilterLine(_ name: String, _ cfg: DomainFilterConfig) -> String {
        let label = "\(name):".padding(toLength: 16, withPad: " ", startingAt: 0)
        if !cfg.enabled {
            return "\(label)disabled"
        }
        var parts = "enabled   mode: \(cfg.mode.rawValue)"
        if cfg.mode != .all && !cfg.items.isEmpty {
            parts += "   items: \(cfg.items.joined(separator: ", "))"
        }
        return "\(label)\(parts)"
    }

    private static func domainLine(_ name: String, _ cfg: DomainConfig) -> String {
        let label = "\(name):".padding(toLength: 16, withPad: " ", startingAt: 0)
        return "\(label)\(cfg.enabled ? "enabled" : "disabled")"
    }

    private static func tildeContract(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
