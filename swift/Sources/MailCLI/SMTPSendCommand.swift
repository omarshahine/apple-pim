import ArgumentParser
import Darwin
import Foundation
import PIMConfig

// MARK: - Shared defaults

private enum SMTPDefaultsConstants {
    static let iCloudHost = "smtp.mail.me.com"
    static let iCloudPort = 465
    static let starttlsPort = 587
    static let defaultSecretKey = "smtp.icloud.password"
}

/// CLI-facing TLS mode argument. Bridges to `SMTPClient.TLSMode`.
enum TLSModeArg: String, ExpressibleByArgument, CaseIterable {
    case implicit
    case starttls

    var asClientMode: SMTPClient.TLSMode {
        switch self {
        case .implicit: return .implicit
        case .starttls: return .starttls
        }
    }
}

// MARK: - smtp-send

struct SMTPSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smtp-send",
        abstract: "Send an email via direct SMTP (no Mail.app).",
        discussion: """
        Defaults to implicit TLS on port 465 (iCloud) with AUTH LOGIN and an
        app-specific password. For servers that only expose STARTTLS on port 587
        (corporate Exchange, self-hosted Postfix, some university/ISP relays) pass
        --tls-mode starttls (port defaults to 587). The password is resolved in
        order: environment variable → ~/.openclaw/secrets.json →
        ~/.config/apple-pim/secrets.json.

        Messages sent via this path do NOT appear in Mail.app's Sent folder.
        Use `mail-cli send` if Sent-folder visibility is required.
        """
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, parsing: .singleValue, help: "Recipient address (repeatable).")
    var to: [String] = []

    @Option(name: .long, parsing: .singleValue, help: "Cc address (repeatable).")
    var cc: [String] = []

    @Option(name: .long, parsing: .singleValue, help: "Bcc address (repeatable). Excluded from rendered headers.")
    var bcc: [String] = []

    @Option(name: .long, help: "Subject line.")
    var subject: String

    @Option(name: .long, help: "Plain-text body. Combine with --html-file for multipart/alternative.")
    var body: String?

    @Option(name: .customLong("html-file"), help: "Path to HTML body file (UTF-8).")
    var htmlFile: String?

    @Option(name: .long, parsing: .singleValue, help: "Attachment file path (repeatable).")
    var attachment: [String] = []

    @Option(name: .long, help: "From address. Defaults to smtp.username from config.")
    var from: String?

    @Option(name: .long, help: "SMTP host. Default: smtp.mail.me.com.")
    var host: String?

    @Option(name: .long, help: "SMTP port. Default: 465 (implicit TLS) or 587 (starttls).")
    var port: Int?

    @Option(name: .customLong("tls-mode"), help: "TLS transport: implicit (port 465, default) or starttls (port 587).")
    var tlsMode: TLSModeArg?

    @Flag(name: .customLong("tls-insecure-skip-verify"),
          help: "Skip TLS certificate verification (starttls only; for self-signed test servers).")
    var tlsInsecureSkipVerify = false

    @Flag(inversion: .prefixedNo, exclusivity: .chooseLast,
          help: "APPEND the sent message to the IMAP Sent folder so it appears in Mail.app/iCloud. Defaults on for iCloud SMTP (*.mail.me.com), off otherwise.")
    var imapAppendSent: Bool?

    @Option(name: .customLong("secret-key"), help: "Secret key for password lookup. Default: smtp.icloud.password.")
    var secretKey: String?

    @Flag(name: .customLong("dry-run"), help: "Render the MIME message to stdout and exit without sending.")
    var dryRun = false

    @Flag(name: .long, help: "Log SMTP conversation to stderr (password redacted).")
    var verbose = false

    @Option(name: .long, help: "Connection timeout in seconds. Default: 30.")
    var timeout: Double = 30

    func validate() throws {
        if to.isEmpty {
            throw ValidationError("at least one --to address required")
        }
        if body == nil && htmlFile == nil {
            throw ValidationError("at least one of --body or --html-file required")
        }
        for path in attachment {
            let expanded = (path as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: expanded) {
                throw ValidationError("attachment not found: \(path)")
            }
        }
        if let htmlFile {
            let expanded = (htmlFile as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: expanded) {
                throw ValidationError("--html-file not found: \(htmlFile)")
            }
        }
    }

    func run() async throws {
        let config = pimOptions.loadConfig()
        let (host, port, fromAddr, resolvedTLSMode) = try resolveConnectionSettings(config: config)
        let effectiveSecretKey = secretKey
            ?? config.smtp?.secretKey
            ?? SMTPDefaultsConstants.defaultSecretKey

        // Load body content
        let htmlContent: String?
        if let htmlFile {
            htmlContent = try String(contentsOfFile: (htmlFile as NSString).expandingTildeInPath, encoding: .utf8)
        } else {
            htmlContent = nil
        }

        let attachments = try attachment.map { path -> Attachment in
            let expanded = (path as NSString).expandingTildeInPath
            let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
            let filename = (expanded as NSString).lastPathComponent
            let contentType = Self.guessContentType(for: filename)
            return Attachment(filename: filename, contentType: contentType, data: data)
        }

        let message = MIMEMessage(
            from: fromAddr,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            text: body,
            html: htmlContent,
            attachments: attachments
        )

        if dryRun {
            let rendered = try message.render()
            FileHandle.standardOutput.write(rendered)
            return
        }

        guard let password = SecretsStore.resolve(effectiveSecretKey) else {
            throw CLIError.invalidInput(
                "no password found. Set one with: mail-cli secrets set \(effectiveSecretKey)  " +
                "(or export \(SecretsStore.envVarName(for: effectiveSecretKey)))"
            )
        }

        let smtpUser = config.smtp?.username ?? fromAddr
        let client = SMTPClient(
            host: host,
            port: port,
            credentials: .init(username: smtpUser, password: password),
            verbose: verbose,
            timeout: timeout,
            tlsMode: resolvedTLSMode,
            insecureSkipVerify: tlsInsecureSkipVerify
        )

        let result: SMTPSendResult
        do {
            result = try await client.sendMessage(message)
        } catch {
            // Surface structured error for JSON output rather than stack-trace-style print.
            outputJSON([
                "success": false,
                "error": String(describing: error),
                "host": host,
                "port": port,
            ])
            throw ExitCode(1)
        }

        // Optionally APPEND the sent message to the IMAP Sent folder so it shows
        // up in Mail.app / iCloud.com. APPEND failures are non-fatal — the message
        // was already delivered by SMTP.
        var imapAppendResult: [String: Any]? = nil
        if let appendCfg = resolveIMAPAppend(config: config, smtpHost: host, smtpUser: smtpUser, smtpPassword: password) {
            // Use the wire Message-ID and original date so the Sent copy matches.
            var sentCopy = message
            sentCopy.messageID = result.messageID
            do {
                let rendered = try sentCopy.render()
                let imap = IMAPClient(
                    host: appendCfg.host,
                    port: appendCfg.port,
                    credentials: .init(username: appendCfg.username, password: appendCfg.password),
                    sentFolder: appendCfg.sentFolder,
                    verbose: verbose,
                    timeout: timeout
                )
                try await imap.appendToSent(rendered, internalDate: sentCopy.date)
                imapAppendResult = ["success": true, "folder": appendCfg.sentFolder, "host": appendCfg.host]
            } catch {
                imapAppendResult = ["success": false, "error": String(describing: error)]
                FileHandle.standardError.write(Data(
                    "warning: SMTP delivery succeeded but IMAP APPEND to Sent failed: \(error)\n".utf8
                ))
            }
        } else {
            // No APPEND — keep the existing Sent-folder note.
            FileHandle.standardError.write(Data(
                "note: message will not appear in Mail.app Sent folder; pass --imap-append-sent (or use 'mail-cli send') if Sent-folder visibility is required.\n".utf8
            ))
        }

        var json: [String: Any] = [
            "success": result.allSucceeded,
            "accepted": result.accepted,
            "rejected": result.rejected.map { ["address": $0.address, "code": $0.response.code, "message": $0.response.firstText] },
            "messageId": result.messageID,
            "host": host,
            "port": port,
        ]
        if let imapAppendResult { json["imap_append"] = imapAppendResult }
        outputJSON(json)
    }

    private func resolveConnectionSettings(config: PIMConfiguration) throws
        -> (host: String, port: Int, from: String, tlsMode: SMTPClient.TLSMode)
    {
        // TLS mode: explicit flag → config (tls_mode) → implicit default.
        let tlsMode: SMTPClient.TLSMode
        if let arg = self.tlsMode {
            tlsMode = arg.asClientMode
        } else if let configMode = config.smtp?.tlsMode,
                  let parsed = SMTPClient.TLSMode(rawValue: configMode.lowercased()) {
            tlsMode = parsed
        } else {
            tlsMode = .implicit
        }

        let host = self.host ?? config.smtp?.host ?? SMTPDefaultsConstants.iCloudHost
        // Port: explicit flag → config → mode-appropriate default (465 implicit, 587 starttls).
        let defaultPort = tlsMode == .starttls
            ? SMTPDefaultsConstants.starttlsPort
            : SMTPDefaultsConstants.iCloudPort
        let port = self.port ?? config.smtp?.port ?? defaultPort

        guard let fromAddr = self.from ?? config.smtp?.username else {
            throw ValidationError("--from required (or set smtp.username in config.json)")
        }
        return (host, port, fromAddr, tlsMode)
    }

    private struct ResolvedIMAP {
        let host: String
        let port: Int
        let username: String
        let password: String
        let sentFolder: String
    }

    /// Resolve whether and how to APPEND the sent message to the IMAP Sent folder.
    /// Returns nil when APPEND is disabled or under-configured (a non-iCloud host
    /// with no `imap.host` set can't be guessed, so we skip rather than fail).
    ///
    /// Enablement: `--imap-append-sent`/`--no-imap-append-sent` → `imap.append_sent`
    /// config → default-on only for iCloud SMTP (`*.mail.me.com`).
    private func resolveIMAPAppend(
        config: PIMConfiguration,
        smtpHost: String,
        smtpUser: String,
        smtpPassword: String
    ) -> ResolvedIMAP? {
        let isICloud = smtpHost.hasSuffix(".mail.me.com")

        let enabled = imapAppendSent
            ?? config.imap?.appendSent
            ?? isICloud
        guard enabled else { return nil }

        // Host: explicit imap.host → iCloud default → can't guess (skip).
        guard let imapHost = config.imap?.host ?? (isICloud ? "imap.mail.me.com" : nil) else {
            FileHandle.standardError.write(Data(
                "warning: --imap-append-sent requested but no imap.host configured for a non-iCloud server; skipping APPEND.\n".utf8
            ))
            return nil
        }
        let imapPort = config.imap?.port ?? 993
        let username = config.imap?.username ?? smtpUser
        // Password: dedicated imap secret key if set, else reuse the SMTP password
        // (iCloud uses the same app-specific password for SMTP and IMAP).
        let password = config.imap?.secretKey.flatMap { SecretsStore.resolve($0) } ?? smtpPassword
        let sentFolder = config.imap?.sentFolder ?? "Sent Messages"

        return ResolvedIMAP(
            host: imapHost, port: imapPort, username: username,
            password: password, sentFolder: sentFolder
        )
    }

    /// Lightweight content-type guesser. The heavy-handed alternative would be to
    /// link UniformTypeIdentifiers; for a handful of common types this map suffices.
    static func guessContentType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "html", "htm": return "text/html"
        case "txt", "log": return "text/plain"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "csv": return "text/csv"
        case "zip": return "application/zip"
        case "ics": return "text/calendar"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - secrets (group)

struct Secrets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Manage secrets used by mail-cli (SMTP passwords, API tokens).",
        discussion: """
        Secrets are stored as JSON at either ~/.openclaw/secrets.json (shared with
        OpenClaw) or ~/.config/apple-pim/secrets.json (standalone). Keys use dotted
        form (e.g. smtp.icloud.password) and map to JSON pointers inside the file.
        Files are enforced at mode 0600.
        """,
        subcommands: [SecretsSet.self, SecretsGet.self, SecretsList.self, SecretsUnset.self]
    )
}

struct SecretsSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Prompt for a secret value and store it."
    )

    @Argument(help: "Secret key in dotted form (e.g. smtp.icloud.password).")
    var key: String

    @Option(name: .long, help: "Target store: openclaw | standalone | auto.")
    var store: StoreChoice = .auto

    @Option(name: .long, help: "Value (non-interactive). Prefer interactive prompt for real secrets.")
    var value: String?

    enum StoreChoice: String, ExpressibleByArgument {
        case openclaw, standalone, auto
        var asKind: SecretsStoreKind {
            switch self {
            case .openclaw: return .openclaw
            case .standalone: return .standalone
            case .auto: return .auto
            }
        }
    }

    func run() throws {
        try SecretsStore.validateKey(key)
        let resolved: String
        if let v = value, !v.isEmpty {
            resolved = v
        } else {
            guard let prompted = SecretsSet.readSecretSilently(prompt: "Value for \(key): ") else {
                throw CLIError.invalidInput("no value provided")
            }
            resolved = prompted
        }
        let kind = try SecretsStore.write(key, value: resolved, to: store.asKind)
        outputJSON([
            "success": true,
            "key": key,
            "store": kind.rawValue,
            "path": SecretsStore.path(for: kind).path,
        ])
    }

    /// Disable tty echo, read one line, restore echo. Works over ssh + interactive shells.
    /// Falls back to a plain readLine() when stdin is not a terminal.
    static func readSecretSilently(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        if isatty(STDIN_FILENO) == 0 {
            return readLine()
        }
        var saved = termios()
        if tcgetattr(STDIN_FILENO, &saved) != 0 {
            return readLine()
        }
        var modified = saved
        modified.c_lflag &= ~tcflag_t(ECHO)
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &modified)
        let value = readLine()
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        FileHandle.standardError.write(Data("\n".utf8))
        return value
    }
}

struct SecretsGet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print a secret value. Resolves in order: env → openclaw → standalone."
    )

    @Argument(help: "Secret key.")
    var key: String

    @Option(name: .long, help: "Force a specific store instead of the resolution chain.")
    var store: SecretsSet.StoreChoice?

    func run() throws {
        try SecretsStore.validateKey(key)
        if let store {
            let value = try SecretsStore.read(key, from: store.asKind)
            print(value)
            return
        }
        guard let value = SecretsStore.resolve(key) else {
            throw CLIError.notFound("secret '\(key)' not found")
        }
        print(value)
    }
}

struct SecretsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List keys in a store (values are never printed)."
    )

    @Option(name: .long, help: "Which store: openclaw | standalone. Default: standalone.")
    var store: SecretsSet.StoreChoice = .standalone

    func run() throws {
        let keys = try SecretsStore.list(from: store.asKind)
        outputJSON([
            "store": store.rawValue,
            "path": SecretsStore.path(for: store.asKind).path,
            "keys": keys,
        ])
    }
}

struct SecretsUnset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unset",
        abstract: "Remove a secret from the store."
    )

    @Argument(help: "Secret key.")
    var key: String

    @Option(name: .long, help: "Target store: openclaw | standalone | auto. Default: auto.")
    var store: SecretsSet.StoreChoice = .auto

    func run() throws {
        try SecretsStore.validateKey(key)
        let removed = try SecretsStore.unset(key, from: store.asKind)
        outputJSON([
            "success": removed,
            "key": key,
            "store": store.rawValue,
            "removed": removed,
        ])
    }
}
