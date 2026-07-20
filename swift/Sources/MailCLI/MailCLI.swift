import ArgumentParser
import AppKit
import Foundation
import PIMConfig

@main
struct MailCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail-cli",
        abstract: "Manage macOS Mail.app via JXA (JavaScript for Automation)",
        subcommands: [
            AuthStatus.self,
            ListAccounts.self,
            ListMailboxes.self,
            ListMessages.self,
            GetMessage.self,
            SearchMessages.self,
            UpdateMessage.self,
            MoveMessage.self,
            DeleteMessage.self,
            BatchUpdateMessages.self,
            BatchDeleteMessages.self,
            SendMessage.self,
            ReplyMessage.self,
            SaveAttachment.self,
            AuthCheck.self,
            ConfigCommand.self,
            SMTPSend.self,
            Secrets.self,
        ]
    )
}

// MARK: - Auth Status (no prompts)

struct AuthStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth-status",
        abstract: "Check Mail.app automation authorization status without triggering prompts"
    )

    func run() throws {
        let status: String

        // Envelope Index (SQLite fast path) readability — independent of
        // Mail.app automation permission; reflects Full Disk Access.
        let envelopeIndex: [String: Any]
        if let engine = try? SQLiteEngine() {
            envelopeIndex = engine.authStatusInfo()
        } else {
            envelopeIndex = ["readable": false]
        }

        // Check if Mail.app is running first
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.mail"
        }
        guard running else {
            let result: [String: Any] = [
                "authorization": "unavailable",
                "message": "Mail.app is not running",
                "envelopeIndex": envelopeIndex,
            ]
            let data = try JSONSerialization.data(withJSONObject: result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        // Use AEDeterminePermissionToAutomateTarget to check without prompting
        let mailDesc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.mail")
        let errCode = AEDeterminePermissionToAutomateTarget(
            mailDesc.aeDesc,
            typeWildCard,
            typeWildCard,
            false  // false = don't prompt
        )

        switch errCode {
        case noErr:
            status = "authorized"
        case OSStatus(-1744): // errAEEventWouldRequireUserConsent
            status = "notDetermined"
        case OSStatus(-1743): // errAEEventNotPermitted
            status = "denied"
        case OSStatus(-600): // procNotFound
            status = "unavailable"
        default:
            status = "error"
        }

        let result: [String: Any] = ["authorization": status, "envelopeIndex": envelopeIndex]
        let data = try JSONSerialization.data(withJSONObject: result)
        print(String(data: data, encoding: .utf8)!)
    }
}

// MARK: - Shared Utilities

enum CLIError: Error, LocalizedError {
    case appNotRunning(String)
    case jxaError(String)
    case notFound(String)
    case invalidInput(String)
    case timeout(String)
    case accessDenied(String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let msg): return msg
        case .jxaError(let msg): return msg
        case .notFound(let msg): return msg
        case .invalidInput(let msg): return msg
        case .timeout(let msg): return msg
        case .accessDenied(let msg): return msg
        }
    }
}

// MARK: - PIMConfig Helpers

func checkMailEnabled(config: PIMConfiguration) throws {
    guard config.mail.enabled else {
        throw CLIError.accessDenied("Mail access is disabled by PIM configuration")
    }
}

/// In `--engine sqlite` mode a fast-path failure is fatal; in auto mode the
/// caller falls through to JXA.
func rethrowIfForcedSQLite(_ engine: EngineChoice, _ error: Error) throws {
    guard engine == .sqlite else { return }
    let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    throw CLIError.accessDenied(
        "SQLite engine failed: \(detail) (retry with --engine auto or jxa, or grant Full Disk Access)")
}

func outputJSON(_ value: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

/// Escape a string for safe interpolation into JXA string literals (single or double quoted).
/// Escapes backslashes first, then quotes and control characters.
func escapeForJXA(_ s: String) -> String {
    return s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

/// Parse an ISO 8601 date string (YYYY-MM-DD or full datetime) into a JXA-safe Date constructor argument.
/// Returns the validated ISO string suitable for `new Date('...')` in JXA, or nil if invalid.
func parseISO8601ForJXA(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }

    let isoFull = ISO8601DateFormatter()
    isoFull.formatOptions = [.withInternetDateTime]
    if let date = isoFull.date(from: trimmed) {
        return isoFull.string(from: date)
    }

    isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFull.date(from: trimmed) {
        let out = ISO8601DateFormatter()
        out.formatOptions = [.withInternetDateTime]
        return out.string(from: date)
    }

    let dateOnly = DateFormatter()
    dateOnly.dateFormat = "yyyy-MM-dd"
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.timeZone = TimeZone.current
    if let date = dateOnly.date(from: trimmed) {
        let out = ISO8601DateFormatter()
        out.formatOptions = [.withInternetDateTime]
        return out.string(from: date)
    }

    return nil
}

/// Escape a string for safe interpolation into AppleScript string literals (double-quoted).
func escapeForAppleScript(_ s: String) -> String {
    return s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

/// Run an AppleScript string via osascript (not JXA). Returns stdout as a string.
func runAppleScript(_ script: String) throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    proc.standardOutput = stdoutPipe
    proc.standardError = stderrPipe

    try proc.run()

    var stdoutData = Data()
    var stderrData = Data()
    let readGroup = DispatchGroup()

    readGroup.enter()
    DispatchQueue.global().async {
        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global().async {
        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }

    let deadline = DispatchTime.now() + .seconds(30)
    let waitGroup = DispatchGroup()
    waitGroup.enter()
    DispatchQueue.global().async {
        proc.waitUntilExit()
        waitGroup.leave()
    }
    let result = waitGroup.wait(timeout: deadline)
    if result == .timedOut {
        proc.terminate()
        throw CLIError.timeout("Mail.app did not respond within 30 seconds")
    }

    readGroup.wait()

    let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard proc.terminationStatus == 0 else {
        if stderrStr.contains("not allowed to send keystrokes") || stderrStr.contains("not allowed assistive access") {
            throw CLIError.accessDenied("Grant access in System Settings > Privacy & Security > Automation")
        }
        throw CLIError.jxaError(stderrStr.isEmpty ? "AppleScript failed with exit code \(proc.terminationStatus)" : stderrStr)
    }

    return String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Returns a JXA function that infers MIME type from a mail attachment.
/// Tries the native `att.mimeType()` first; falls back to file-extension lookup.
func inferMimeJXA() -> String {
    return """
    function inferMime(att) {
        try { var m = att.mimeType(); if (m) return m; } catch(e) {}
        var name = att.name() || '';
        var dot = name.lastIndexOf('.');
        if (dot < 0) return 'application/octet-stream';
        var ext = name.slice(dot + 1).toLowerCase();
        var map = {
            md:'text/markdown', txt:'text/plain', pdf:'application/pdf',
            jpg:'image/jpeg', jpeg:'image/jpeg', png:'image/png', gif:'image/gif',
            doc:'application/msword',
            docx:'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            xls:'application/vnd.ms-excel',
            xlsx:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            pptx:'application/vnd.openxmlformats-officedocument.presentationml.presentation',
            csv:'text/csv', html:'text/html', htm:'text/html',
            json:'application/json', xml:'application/xml', rtf:'application/rtf',
            zip:'application/zip', gz:'application/gzip'
        };
        return map[ext] || 'application/octet-stream';
    }
    """
}

/// Validate that a destination directory is within the user's home or system temp.
/// Directory/path components that must never be a write target, even inside the
/// home directory. Blocks credential stores and login-persistence locations so a
/// prompt-injected agent cannot drop an attachment into `~/Library/LaunchAgents`
/// or overwrite material under `~/.ssh`. Mirrors the read-side denylist in
/// lib/safe-attachments.js.
private let deniedDestComponents: Set<String> = [
    ".ssh", ".aws", ".gnupg", ".kube", ".docker",
    ".secrets", ".chezmoi", "Keychains",
    "LaunchAgents", "LaunchDaemons",
]

/// Canonicalize a path that may not exist yet by resolving symlinks on its
/// deepest existing ancestor, then re-appending the not-yet-created tail. This
/// lets `validateDestDir` run *before* the directory is created, so a rejected
/// target never leaves a stray directory behind.
func canonicalizeIntendedPath(_ url: URL) -> String {
    let fm = FileManager.default
    var existing = url.standardizedFileURL   // resolves ".." lexically
    var tail: [String] = []
    while !fm.fileExists(atPath: existing.path) {
        let parent = existing.deletingLastPathComponent()
        if parent.path == existing.path { break }  // reached root
        tail.insert(existing.lastPathComponent, at: 0)
        existing = parent
    }
    var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
    for comp in tail { resolved.appendPathComponent(comp) }
    return resolved.standardizedFileURL.path
}

/// Prevents agents from writing attachments to arbitrary or sensitive filesystem
/// locations. Confines writes to the home directory or system temp, then rejects
/// sensitive subpaths (credential stores, login-persistence dirs) even within
/// home. Validate the *intended* path before creating it so a rejected target
/// never results in a stray directory.
func validateDestDir(_ url: URL) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
        .resolvingSymlinksInPath().standardizedFileURL.path
    let tmp = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath().standardizedFileURL.path
    let resolved = canonicalizeIntendedPath(url)

    let inHome = resolved == home || resolved.hasPrefix(home + "/")
    let inTmp = resolved == tmp || resolved.hasPrefix(tmp + "/")
    guard inHome || inTmp else {
        throw CLIError.invalidInput("destDir must be within your home directory or system temp directory, got: \(resolved)")
    }

    // Reject sensitive subpaths even when inside home.
    let components = resolved.split(separator: "/").map(String.init)
    for comp in components where deniedDestComponents.contains(comp) {
        throw CLIError.invalidInput("destDir may not target the protected location \"\(comp)\": \(resolved)")
    }
    // Block the plugin's own config/secrets directory.
    if resolved == "\(home)/.config/apple-pim" || resolved.hasPrefix("\(home)/.config/apple-pim/") {
        throw CLIError.invalidInput("destDir may not target the apple-pim config directory: \(resolved)")
    }
}

func ensureMailRunning() throws {
    let running = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.apple.mail"
    }
    guard running else {
        throw CLIError.appNotRunning("Mail.app is not running. Please open Mail.app first.")
    }
}

func runJXA(_ script: String) throws -> Any {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-l", "JavaScript", "-e", script]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    proc.standardOutput = stdoutPipe
    proc.standardError = stderrPipe

    try proc.run()

    // Read pipe data concurrently BEFORE waitUntilExit to prevent deadlock.
    // If output exceeds the ~64KB pipe buffer and we wait first, the child
    // blocks on write and never exits — classic pipe deadlock.
    var stdoutData = Data()
    var stderrData = Data()
    let readGroup = DispatchGroup()

    readGroup.enter()
    DispatchQueue.global().async {
        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global().async {
        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }

    // 30-second timeout
    let deadline = DispatchTime.now() + .seconds(30)
    let waitGroup = DispatchGroup()
    waitGroup.enter()
    DispatchQueue.global().async {
        proc.waitUntilExit()
        waitGroup.leave()
    }
    let result = waitGroup.wait(timeout: deadline)
    if result == .timedOut {
        proc.terminate()
        throw CLIError.timeout("Mail.app did not respond within 30 seconds")
    }

    // Wait for pipe reads to finish (they will, since the process has exited)
    readGroup.wait()

    let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard proc.terminationStatus == 0 else {
        if stderrStr.contains("not allowed to send keystrokes") || stderrStr.contains("not allowed assistive access") {
            throw CLIError.accessDenied("Grant access in System Settings > Privacy & Security > Automation")
        }
        throw CLIError.jxaError(stderrStr.isEmpty ? "JXA script failed with exit code \(proc.terminationStatus)" : stderrStr)
    }

    let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !stdoutStr.isEmpty else {
        return [String: Any]()
    }

    guard let data = stdoutStr.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) else {
        throw CLIError.jxaError("Failed to parse JXA output as JSON: \(stdoutStr.prefix(200))")
    }

    return json
}

// Shared JXA helper for finding a message by ID.
// Accepts optional mailbox/account to narrow the search.
// Priority order: specified mailbox > INBOX/Sent/Archive/Drafts > all mailboxes.
func findMessageJXA(targetId: String, mailbox: String?, account: String?) -> String {
    let escapedId = escapeForJXA(targetId)
    let mailboxFilter = mailbox.map { "'\(escapeForJXA($0))'" } ?? "null"
    let accountFilter = account.map { "'\(escapeForJXA($0))'" } ?? "null"

    return """
    function findMessage() {
        const Mail = Application("Mail");
        const targetId = '\(escapedId)';
        const mboxHint = \(mailboxFilter);
        const acctHint = \(accountFilter);

        function searchInMailbox(mbox) {
            try {
                const found = mbox.messages.whose({messageId: targetId})();
                if (found.length > 0) return found[0];
            } catch(e) {}
            return null;
        }

        // Search priority mailboxes first, then remaining mailboxes
        const priority = ['INBOX',
            'Sent Messages', 'Sent Mail', 'Sent Items',
            'Archive', 'All Mail', 'Drafts',
            'Deleted Messages', 'Deleted Items', 'Trash',
            'Junk', 'Junk Email', 'Junk E-mail', 'Bulk', 'Spam'];
        const accounts = acctHint ? Mail.accounts.whose({name: acctHint})() : Mail.accounts();
        const searched = new Set();

        // If mailbox hint given, try it first (optimization, not a hard filter)
        if (mboxHint) {
            for (let a = 0; a < accounts.length; a++) {
                const mbs = accounts[a].mailboxes.whose({name: mboxHint})();
                for (let m = 0; m < mbs.length; m++) {
                    searched.add(accounts[a].name() + '/' + mbs[m].name());
                    const r = searchInMailbox(mbs[m]);
                    if (r) return r;
                }
            }
        }

        for (let a = 0; a < accounts.length; a++) {
            for (let p = 0; p < priority.length; p++) {
                const mbs = accounts[a].mailboxes.whose({name: priority[p]})();
                for (let m = 0; m < mbs.length; m++) {
                    const key = accounts[a].name() + '/' + mbs[m].name();
                    if (searched.has(key)) continue;
                    searched.add(key);
                    const r = searchInMailbox(mbs[m]);
                    if (r) return r;
                }
            }
        }

        // Search remaining mailboxes (non-priority)
        for (let a = 0; a < accounts.length; a++) {
            const mbs = accounts[a].mailboxes();
            for (let m = 0; m < mbs.length; m++) {
                const key = accounts[a].name() + '/' + mbs[m].name();
                if (searched.has(key)) continue;
                const r = searchInMailbox(mbs[m]);
                if (r) return r;
            }
        }
        return null;
    }
    """
}

/// Build the AppleScript that locates the original message by its numeric Apple Mail
/// id within an account and sends a reply.
///
/// The message is located via a recursive search over the account's mailbox tree
/// rather than a `mailbox "<name>" of account "<acct>"` by-name specifier. The
/// by-name form only resolves DIRECT children of the account, so it fails with
/// -1728 (errAENoSuchObject) for nested mailboxes — notably Gmail/Workspace, where
/// "All Mail" is nested under the "[Gmail]" container. See issue #67.
///
/// The reply is composed `without opening window` so it stays in plain-text mode,
/// where the `content` property is writable. `with opening window` forces HTML mode
/// and drops the body silently. See issue #73.
///
/// `attachmentLines` is the pre-built `make new attachment …` snippet (may be empty).
func buildReplyAppleScript(bodyPath: String, accountName: String, appleMailId: Int, attachmentLines: String) -> String {
    let escapedAccount = escapeForAppleScript(accountName)
    let escapedBodyPath = escapeForAppleScript(bodyPath)
    let attachmentBlock = attachmentLines.isEmpty ? "" : """

        tell replyMsg\(attachmentLines)
        end tell
    """

    return """
    on findMsgById(theId, mboxList)
        tell application "Mail"
            repeat with mb in mboxList
                try
                    set matchList to (messages of mb whose id is theId)
                    if (count of matchList) > 0 then return (item 1 of matchList)
                end try
            end repeat
            repeat with mb in mboxList
                try
                    set subList to (mailboxes of mb)
                    if (count of subList) > 0 then
                        set found to my findMsgById(theId, subList)
                        if found is not missing value then return found
                    end if
                end try
            end repeat
        end tell
        return missing value
    end findMsgById

    set replyBody to read POSIX file "\(escapedBodyPath)" as «class utf8»
    tell application "Mail"
        set theAccount to (first account whose name is "\(escapedAccount)")
        set origMsg to my findMsgById(\(appleMailId), (mailboxes of theAccount))
        if origMsg is missing value then error "Could not locate the original message (id \(appleMailId)) in account \\"\(escapedAccount)\\" to reply to"
        -- `without opening window` is REQUIRED, not cosmetic: `with opening window`
        -- makes Mail compose the reply in rich-text/HTML mode, where the plain-text
        -- `content` property is read-only. Setting it then silently no-ops and the
        -- reply sends with an empty body. See issue #73. Do not change back.
        set replyMsg to reply origMsg without opening window
        set content of replyMsg to replyBody\(attachmentBlock)
        send replyMsg
    end tell
    """
}

/// Generates the JXA `findMsg(targetId)` function for batch operations.
/// Unlike `findMessageJXA`, the target ID is a parameter (not hardcoded).
func batchFindMessageJXA(mailbox: String?, account: String?) -> String {
    let mailboxFilter = mailbox.map { "'\(escapeForJXA($0))'" } ?? "null"
    let accountFilter = account.map { "'\(escapeForJXA($0))'" } ?? "null"

    return """
    const mboxHint = \(mailboxFilter);
    const acctHint = \(accountFilter);

    function findMsg(targetId) {
        // Search priority mailboxes first, then remaining mailboxes
        const priority = ['INBOX',
            'Sent Messages', 'Sent Mail', 'Sent Items',
            'Archive', 'All Mail', 'Drafts',
            'Deleted Messages', 'Deleted Items', 'Trash',
            'Junk', 'Junk Email', 'Junk E-mail', 'Bulk', 'Spam'];
        const accounts = acctHint ? Mail.accounts.whose({name: acctHint})() : Mail.accounts();
        const searched = new Set();

        function searchIn(mbox) {
            try {
                const found = mbox.messages.whose({messageId: targetId})();
                if (found.length > 0) return found[0];
            } catch(e) {}
            return null;
        }

        if (mboxHint) {
            for (let a = 0; a < accounts.length; a++) {
                const mbs = accounts[a].mailboxes.whose({name: mboxHint})();
                for (let m = 0; m < mbs.length; m++) {
                    searched.add(accounts[a].name() + '/' + mbs[m].name());
                    const r = searchIn(mbs[m]);
                    if (r) return r;
                }
            }
        }
        for (let a = 0; a < accounts.length; a++) {
            for (let p = 0; p < priority.length; p++) {
                const mbs = accounts[a].mailboxes.whose({name: priority[p]})();
                for (let m = 0; m < mbs.length; m++) {
                    const key = accounts[a].name() + '/' + mbs[m].name();
                    if (searched.has(key)) continue;
                    searched.add(key);
                    const r = searchIn(mbs[m]);
                    if (r) return r;
                }
            }
        }
        for (let a = 0; a < accounts.length; a++) {
            const mbs = accounts[a].mailboxes();
            for (let m = 0; m < mbs.length; m++) {
                const key = accounts[a].name() + '/' + mbs[m].name();
                if (searched.has(key)) continue;
                const r = searchIn(mbs[m]);
                if (r) return r;
            }
        }
        return null;
    }
    """
}

// MARK: - Commands

struct ListAccounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accounts",
        abstract: "List all mail accounts"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Read engine: auto (SQLite with JXA fallback), sqlite, or jxa")
    var engine: EngineChoice = .auto

    func run() async throws {
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        // Unlike the other read commands, `accounts` prefers JXA in auto mode:
        // Mail.app is the authority on the account inventory (including
        // `enabled` state and accounts with no local mailboxes). SQLite serves
        // it only when forced or when Mail.app is unavailable.
        if engine == .sqlite {
            do {
                outputJSON(try SQLiteEngine().accounts())
                return
            } catch {
                try rethrowIfForcedSQLite(engine, error)
            }
        }

        do {
            try ensureMailRunning()
        } catch where engine == .auto {
            if let result = try? SQLiteEngine().accounts() {
                outputJSON(result)
                return
            }
            throw error
        }

        let script = """
        const Mail = Application("Mail");
        const accounts = Mail.accounts();
        const result = accounts.map(a => ({
            name: a.name(),
            id: a.id(),
            enabled: a.enabled(),
            userName: a.userName(),
            accountType: a.accountType()
        }));
        JSON.stringify(result);
        """

        let result = try runJXA(script)
        outputJSON([
            "success": true,
            "accounts": result
        ])
    }
}

struct ListMailboxes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mailboxes",
        abstract: "List mailboxes with unread counts"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Filter by account name")
    var account: String?

    @Option(name: .long, help: "Read engine: auto (SQLite with JXA fallback), sqlite, or jxa")
    var engine: EngineChoice = .auto

    func run() async throws {
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        if engine != .jxa {
            do {
                outputJSON(try SQLiteEngine().mailboxes(account: account))
                return
            } catch {
                try rethrowIfForcedSQLite(engine, error)
            }
        }

        try ensureMailRunning()

        let accountFilter = account.map { "'\(escapeForJXA($0))'" } ?? "null"

        let script = """
        const Mail = Application("Mail");
        const accountFilter = \(accountFilter);
        const results = [];

        function collectMailboxes(mailboxes, accountName) {
            for (let i = 0; i < mailboxes.length; i++) {
                const mb = mailboxes[i];
                results.push({
                    name: mb.name(),
                    account: accountName,
                    unreadCount: mb.unreadCount(),
                    messageCount: mb.messages.length
                });
            }
        }

        if (accountFilter) {
            const accts = Mail.accounts.whose({name: accountFilter})();
            if (accts.length === 0) {
                JSON.stringify({error: "Account not found: " + accountFilter});
            } else {
                collectMailboxes(accts[0].mailboxes(), accountFilter);
                JSON.stringify(results);
            }
        } else {
            const accounts = Mail.accounts();
            for (let a = 0; a < accounts.length; a++) {
                const acct = accounts[a];
                collectMailboxes(acct.mailboxes(), acct.name());
            }
            JSON.stringify(results);
        }
        """

        let raw = try runJXA(script)

        // Check for error from JXA
        if let dict = raw as? [String: Any], let error = dict["error"] as? String {
            throw CLIError.notFound(error)
        }

        outputJSON([
            "success": true,
            "mailboxes": raw
        ])
    }
}

struct ListMessages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "List messages in a mailbox"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Mailbox name (default: INBOX)")
    var mailbox: String = "INBOX"

    @Option(name: .long, help: "Account name (searches all accounts if omitted)")
    var account: String?

    @Option(name: .long, help: "Maximum messages to return (default: 25)")
    var limit: Int = 25

    @Option(name: .long, help: "Filter: unread, flagged, or all (default: all)")
    var filter: String?

    @Option(name: .long, help: "Read engine: auto (SQLite with JXA fallback), sqlite, or jxa")
    var engine: EngineChoice = .auto

    func run() async throws {
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        if engine != .jxa {
            do {
                outputJSON(try SQLiteEngine().messages(
                    mailbox: mailbox, account: account, limit: limit, filter: filter))
                return
            } catch {
                try rethrowIfForcedSQLite(engine, error)
            }
        }

        try ensureMailRunning()

        let accountFilter = account.map { "'\(escapeForJXA($0))'" } ?? "null"
        let mailboxName = escapeForJXA(mailbox)
        let filterVal = filter.map { "'\(escapeForJXA($0))'" } ?? "null"

        let script = """
        const Mail = Application("Mail");
        const accountFilter = \(accountFilter);
        const mailboxName = '\(mailboxName)';
        const limit = \(limit);
        const filterType = \(filterVal);

        function findMailbox() {
            const accounts = accountFilter
                ? Mail.accounts.whose({name: accountFilter})()
                : Mail.accounts();
            for (let a = 0; a < accounts.length; a++) {
                const mbs = accounts[a].mailboxes.whose({name: mailboxName})();
                if (mbs.length > 0) return mbs[0];
            }
            return null;
        }

        const mbox = findMailbox();
        if (!mbox) {
            JSON.stringify({error: "Mailbox not found: " + mailboxName});
        } else {
            const msgs = mbox.messages;
            const count = msgs.length;
            if (count === 0) {
                JSON.stringify({messages: [], mailbox: mailboxName, totalInMailbox: 0});
            } else {
                const results = [];
                // Scan cap: when filtering, scan up to 10x limit to find enough matches.
                // Without a filter, scan exactly limit messages.
                const scanCap = filterType ? Math.min(count, limit * 10) : Math.min(count, limit);

                // Per-message fetching with error handling (batch .slice can fail on null dates)
                for (let i = 0; i < scanCap && results.length < limit; i++) {
                    try {
                        const m = msgs[i];
                        const isRead = m.readStatus();
                        const isFlagged = m.flaggedStatus();
                        if (filterType === 'unread' && isRead) continue;
                        if (filterType === 'flagged' && !isFlagged) continue;
                        const dr = m.dateReceived();
                        var attCount = 0;
                        try { attCount = m.mailAttachments.length; } catch(e2) {}
                        results.push({
                            messageId: m.messageId(),
                            sender: m.sender(),
                            subject: m.subject(),
                            dateReceived: dr ? dr.toISOString() : null,
                            isRead: isRead,
                            isFlagged: isFlagged,
                            isJunk: m.junkMailStatus(),
                            attachmentCount: attCount
                        });
                    } catch(e) { /* skip messages that fail to read */ }
                }

                JSON.stringify({
                    messages: results,
                    mailbox: mailboxName,
                    totalInMailbox: count
                });
            }
        }
        """

        let raw = try runJXA(script)

        if let dict = raw as? [String: Any], let error = dict["error"] as? String {
            throw CLIError.notFound(error)
        }

        guard let dict = raw as? [String: Any] else {
            outputJSON(["success": true, "messages": [] as [Any], "count": 0])
            return
        }

        let messages = dict["messages"] as? [Any] ?? []
        outputJSON([
            "success": true,
            "mailbox": dict["mailbox"] ?? mailbox,
            "messages": messages,
            "count": messages.count,
            "totalInMailbox": dict["totalInMailbox"] ?? 0
        ])
    }
}

struct GetMessage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a single message by message ID"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "RFC 2822 message ID")
    var id: String

    @Option(name: .long, help: "Mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Account name hint (speeds up lookup)")
    var account: String?

    @Flag(name: .long, help: "Include raw RFC 2822 source in the response")
    var includeSource: Bool = false

    @Option(name: .long, help: "Read engine: auto (SQLite with JXA fallback), sqlite, or jxa")
    var engine: EngineChoice = .auto

    func run() async throws {
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        if engine != .jxa {
            do {
                outputJSON(try SQLiteEngine().get(
                    id: id, includeSource: includeSource,
                    mailboxHint: mailbox, accountHint: account))
                return
            } catch {
                try rethrowIfForcedSQLite(engine, error)
            }
        }

        try ensureMailRunning()

        let findHelper = findMessageJXA(targetId: id, mailbox: mailbox, account: account)

        let script = """
        \(inferMimeJXA())

        \(findHelper)

        const msg = findMessage();
        if (!msg) {
            JSON.stringify({error: "Message not found: \(escapeForJXA(id))"});
        } else {
            const result = {
                messageId: msg.messageId(),
                subject: msg.subject(),
                sender: msg.sender(),
                dateReceived: msg.dateReceived() ? msg.dateReceived().toISOString() : null,
                dateSent: msg.dateSent() ? msg.dateSent().toISOString() : null,
                isRead: msg.readStatus(),
                isFlagged: msg.flaggedStatus(),
                isJunk: msg.junkMailStatus(),
                replyTo: msg.replyTo(),
                mailbox: msg.mailbox().name(),
                account: msg.mailbox().account().name(),
                content: msg.content()
            };

            if (\(includeSource ? "true" : "false")) {
                try {
                    result.source = msg.source();
                } catch(e) {}
            }

            // Get recipients
            try {
                const toRecips = msg.toRecipients();
                result.to = toRecips.map(r => ({name: r.name(), address: r.address()}));
            } catch(e) { result.to = []; }

            try {
                const ccRecips = msg.ccRecipients();
                result.cc = ccRecips.map(r => ({name: r.name(), address: r.address()}));
            } catch(e) { result.cc = []; }

            // Get headers if available
            try {
                result.allHeaders = msg.allHeaders();
            } catch(e) {}

            // Collect attachment metadata
            var attachments = [];
            try {
                var attCount = msg.mailAttachments.length;
                for (var i = 0; i < attCount; i++) {
                    try {
                        var att = msg.mailAttachments[i];
                        attachments.push({
                            index: i,
                            name: att.name(),
                            fileSize: att.fileSize(),
                            downloaded: att.downloaded(),
                            mimeType: inferMime(att)
                        });
                    } catch(e) {}
                }
            } catch(e) {}
            result.attachments = attachments;
            result.attachmentCount = attachments.length;

            JSON.stringify(result);
        }
        """

        let raw = try runJXA(script)

        if let dict = raw as? [String: Any], let error = dict["error"] as? String {
            throw CLIError.notFound(error)
        }

        outputJSON([
            "success": true,
            "message": raw
        ])
    }
}

struct SearchMessages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search messages by subject, sender, or content"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Argument(help: "Search query")
    var query: String

    @Option(name: .long, help: "Search field: subject, sender, content, or all (default: all)")
    var field: String = "all"

    @Option(name: .long, help: "Mailbox name to search in (searches all if omitted)")
    var mailbox: String?

    @Option(name: .long, help: "Account name")
    var account: String?

    @Option(name: .long, help: "Maximum results (default: 25)")
    var limit: Int = 25

    @Option(name: .long, help: "Only messages received on or after this date (ISO 8601: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)")
    var since: String?

    @Option(name: .long, help: "Read engine: auto (SQLite with JXA fallback), sqlite, or jxa")
    var engine: EngineChoice = .auto

    func run() async throws {
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        if engine != .jxa {
            do {
                outputJSON(try SQLiteEngine().search(
                    query: query, field: field, mailbox: mailbox, account: account,
                    limit: limit, since: since))
                return
            } catch {
                try rethrowIfForcedSQLite(engine, error)
            }
        }

        try ensureMailRunning()

        let escapedQuery = escapeForJXA(query.lowercased())
        let accountFilter = account.map { "'\(escapeForJXA($0))'" } ?? "null"
        let mailboxFilter = mailbox.map { "'\(escapeForJXA($0))'" } ?? "null"
        let escapedField = escapeForJXA(field)

        let sinceParam: String
        if let since = since {
            guard let isoDate = parseISO8601ForJXA(since) else {
                throw CLIError.invalidInput("Invalid date format for --since. Use ISO 8601: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ")
            }
            sinceParam = "new Date('\(escapeForJXA(isoDate))')"
        } else {
            sinceParam = "null"
        }

        let script = """
        const Mail = Application("Mail");
        const query = '\(escapedQuery)';
        const searchField = '\(escapedField)';
        const accountFilter = \(accountFilter);
        const mailboxFilter = \(mailboxFilter);
        const limit = \(limit);
        const sinceDate = \(sinceParam);
        const results = [];

        function searchMailbox(mbox, accountName) {
            if (results.length >= limit) return;

            // Build .whose() predicate for server-side filtering.
            // subject, sender, and 'all' (subject OR sender) use _contains.
            // content requires client-side matching (body not in .whose()).
            var predicate = {};
            if (sinceDate) {
                predicate.dateReceived = {">=": sinceDate};
            }
            if (searchField === 'subject') {
                predicate.subject = {_contains: query};
            } else if (searchField === 'sender') {
                predicate.sender = {_contains: query};
            } else if (searchField === 'all') {
                predicate._or = [{subject: {_contains: query}}, {sender: {_contains: query}}];
            }

            const useWhose = Object.keys(predicate).length > 0;
            const needsClientMatch = searchField === 'content';
            const msgs = useWhose ? mbox.messages.whose(predicate)() : mbox.messages;
            const count = msgs.length;
            const batchSize = needsClientMatch ? Math.min(count, 500) : Math.min(count, limit);

            for (let i = 0; i < batchSize && results.length < limit; i++) {
                try {
                    const m = msgs[i];

                    if (needsClientMatch) {
                        let match = false;
                        try { match = (m.content() || '').toLowerCase().includes(query); } catch(e2) {}
                        if (!match) continue;
                    }

                    const dr = m.dateReceived();
                    results.push({
                        messageId: m.messageId(),
                        sender: m.sender(),
                        subject: m.subject(),
                        dateReceived: dr ? dr.toISOString() : null,
                        isRead: m.readStatus(),
                        isFlagged: m.flaggedStatus(),
                        mailbox: mbox.name(),
                        account: accountName
                    });
                } catch(e) { /* skip messages that fail to read */ }
            }
        }

        const accounts = accountFilter
            ? Mail.accounts.whose({name: accountFilter})()
            : Mail.accounts();

        for (let a = 0; a < accounts.length && results.length < limit; a++) {
            const acct = accounts[a];
            const mbs = mailboxFilter
                ? acct.mailboxes.whose({name: mailboxFilter})()
                : acct.mailboxes();
            for (let m = 0; m < mbs.length && results.length < limit; m++) {
                searchMailbox(mbs[m], acct.name());
            }
        }

        JSON.stringify(results);
        """

        let raw = try runJXA(script)
        let messages = raw as? [Any] ?? []

        outputJSON([
            "success": true,
            "query": query,
            "field": field,
            "messages": messages,
            "count": messages.count
        ])
    }
}

struct UpdateMessage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update message flags (read/unread, flagged, junk)"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "RFC 2822 message ID")
    var id: String

    @Option(name: .long, help: "Set read status (true/false)")
    var read: String?

    @Option(name: .long, help: "Set flagged status (true/false)")
    var flagged: String?

    @Option(name: .long, help: "Set junk status (true/false)")
    var junk: String?

    @Option(name: .long, help: "Mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Account name hint (speeds up lookup)")
    var account: String?

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        var updates = [String]()
        if let read = read {
            updates.append("msg.readStatus = \(read == "true" ? "true" : "false");")
        }
        if let flagged = flagged {
            updates.append("msg.flaggedStatus = \(flagged == "true" ? "true" : "false");")
        }
        if let junk = junk {
            updates.append("msg.junkMailStatus = \(junk == "true" ? "true" : "false");")
        }

        guard !updates.isEmpty else {
            throw CLIError.invalidInput("No updates specified. Use --read, --flagged, or --junk.")
        }

        let updateCode = updates.joined(separator: "\n            ")
        let findHelper = findMessageJXA(targetId: id, mailbox: mailbox, account: account)

        let script = """
        \(findHelper)

        const msg = findMessage();
        if (!msg) {
            JSON.stringify({error: "Message not found: \(escapeForJXA(id))"});
        } else {
            \(updateCode)
            JSON.stringify({
                messageId: msg.messageId(),
                subject: msg.subject(),
                isRead: msg.readStatus(),
                isFlagged: msg.flaggedStatus(),
                isJunk: msg.junkMailStatus()
            });
        }
        """

        let raw = try runJXA(script)

        if let dict = raw as? [String: Any], let error = dict["error"] as? String {
            throw CLIError.notFound(error)
        }

        outputJSON([
            "success": true,
            "message": "Message updated successfully",
            "result": raw
        ])
    }
}

struct MoveMessage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move message to a different mailbox"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "RFC 2822 message ID")
    var id: String

    @Option(name: .long, help: "Destination mailbox name")
    var toMailbox: String

    @Option(name: .long, help: "Destination account name (uses same account if omitted)")
    var toAccount: String?

    @Option(name: .long, help: "Source mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Source account name hint (speeds up lookup)")
    var account: String?

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        let escapedMailbox = escapeForJXA(toMailbox)
        let toAccountFilter = toAccount.map { "'\(escapeForJXA($0))'" } ?? "null"
        let findHelper = findMessageJXA(targetId: id, mailbox: mailbox, account: account)

        let script = """
        \(findHelper)

        const Mail = Application("Mail");
        const destMailboxName = '\(escapedMailbox)';
        const destAccountName = \(toAccountFilter);

        function findDestMailbox(sourceAccount) {
            const accounts = destAccountName
                ? Mail.accounts.whose({name: destAccountName})()
                : [sourceAccount];
            for (let a = 0; a < accounts.length; a++) {
                const mbs = accounts[a].mailboxes.whose({name: destMailboxName})();
                if (mbs.length > 0) return mbs[0];
            }
            return null;
        }

        const msg = findMessage();
        if (!msg) {
            JSON.stringify({error: "Message not found: \(escapeForJXA(id))"});
        } else {
            const sourceAccount = msg.mailbox().account();
            const destMbox = findDestMailbox(sourceAccount);
            if (!destMbox) {
                JSON.stringify({error: "Destination mailbox not found: " + destMailboxName});
            } else {
                const fromMailbox = msg.mailbox().name();
                Mail.move(msg, {to: destMbox});
                JSON.stringify({
                    messageId: '\(escapeForJXA(id))',
                    from: fromMailbox,
                    to: destMailboxName,
                    moved: true
                });
            }
        }
        """

        let raw = try runJXA(script)

        if let dict = raw as? [String: Any], let error = dict["error"] as? String {
            throw CLIError.notFound(error)
        }

        outputJSON([
            "success": true,
            "message": "Message moved successfully",
            "result": raw
        ])
    }
}

struct DeleteMessage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete message (move to Trash)"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "RFC 2822 message ID")
    var id: String

    @Option(name: .long, help: "Mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Account name hint (speeds up lookup)")
    var account: String?

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        let findHelper = findMessageJXA(targetId: id, mailbox: mailbox, account: account)

        let script = """
        \(findHelper)

        const Mail = Application("Mail");
        const msg = findMessage();
        if (!msg) {
            JSON.stringify({error: "Message not found: \(escapeForJXA(id))"});
        } else {
            const subject = msg.subject();
            const mboxName = msg.mailbox().name();
            Mail.delete(msg);
            JSON.stringify({
                messageId: '\(escapeForJXA(id))',
                subject: subject,
                fromMailbox: mboxName,
                deleted: true
            });
        }
        """

        let raw = try runJXA(script)

        if let dict = raw as? [String: Any], let error = dict["error"] as? String {
            throw CLIError.notFound(error)
        }

        outputJSON([
            "success": true,
            "message": "Message deleted (moved to Trash)",
            "result": raw
        ])
    }
}

// MARK: - Batch Operations

struct BatchUpdateInput: Codable {
    let id: String
    let read: Bool?
    let flagged: Bool?
    let junk: Bool?
}

struct BatchUpdateMessages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch-update",
        abstract: "Update flags on multiple messages in a single JXA call"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "JSON array of update objects: [{\"id\": \"...\", \"read\": true}, ...]")
    var json: String

    @Option(name: .long, help: "Mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Account name hint (speeds up lookup)")
    var account: String?

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        guard let data = json.data(using: .utf8),
              let updates = try? JSONDecoder().decode([BatchUpdateInput].self, from: data) else {
            throw CLIError.invalidInput("Invalid JSON format. Expected an array of update objects with 'id' and optional 'read', 'flagged', 'junk' fields.")
        }

        if updates.isEmpty {
            throw CLIError.invalidInput("Updates array cannot be empty")
        }

        // Build the updates array as a JS literal
        let jsUpdates = updates.map { update -> String in
            var fields = [String]()
            fields.append("id: '\(escapeForJXA(update.id))'")
            if let read = update.read { fields.append("read: \(read)") }
            if let flagged = update.flagged { fields.append("flagged: \(flagged)") }
            if let junk = update.junk { fields.append("junk: \(junk)") }
            return "{\(fields.joined(separator: ", "))}"
        }.joined(separator: ",\n            ")

        let findMsgFunc = batchFindMessageJXA(mailbox: mailbox, account: account)

        let script = """
        const Mail = Application("Mail");
        const updates = [
            \(jsUpdates)
        ];
        \(findMsgFunc)

        const results = [];
        const errors = [];

        for (const u of updates) {
            try {
                const msg = findMsg(u.id);
                if (!msg) {
                    errors.push({id: u.id, error: 'Message not found'});
                    continue;
                }
                if (u.read !== undefined) msg.readStatus = u.read;
                if (u.flagged !== undefined) msg.flaggedStatus = u.flagged;
                if (u.junk !== undefined) msg.junkMailStatus = u.junk;
                results.push({
                    id: u.id,
                    subject: msg.subject(),
                    isRead: msg.readStatus(),
                    isFlagged: msg.flaggedStatus(),
                    isJunk: msg.junkMailStatus()
                });
            } catch(e) {
                errors.push({id: u.id, error: e.message || String(e)});
            }
        }

        JSON.stringify({results: results, errors: errors});
        """

        let raw = try runJXA(script)

        guard let dict = raw as? [String: Any] else {
            throw CLIError.jxaError("Unexpected output from batch update")
        }

        let results = dict["results"] as? [Any] ?? []
        let errors = dict["errors"] as? [Any] ?? []

        outputJSON([
            "success": errors.isEmpty,
            "message": "Batch update completed",
            "updated": results,
            "updatedCount": results.count,
            "errors": errors,
            "errorCount": errors.count
        ])
    }
}

struct BatchDeleteMessages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch-delete",
        abstract: "Delete multiple messages in a single JXA call (moves to Trash)"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "JSON array of RFC 2822 message IDs to delete")
    var json: String

    @Option(name: .long, help: "Mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Account name hint (speeds up lookup)")
    var account: String?

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            throw CLIError.invalidInput("Invalid JSON format. Expected an array of message ID strings.")
        }

        if ids.isEmpty {
            throw CLIError.invalidInput("IDs array cannot be empty")
        }

        let jsIds = ids.map { "'\(escapeForJXA($0))'" }.joined(separator: ", ")
        let findMsgFunc = batchFindMessageJXA(mailbox: mailbox, account: account)

        let script = """
        const Mail = Application("Mail");
        const ids = [\(jsIds)];
        \(findMsgFunc)

        const results = [];
        const errors = [];

        for (const targetId of ids) {
            try {
                const msg = findMsg(targetId);
                if (!msg) {
                    errors.push({id: targetId, error: 'Message not found'});
                    continue;
                }
                const subject = msg.subject();
                const mboxName = msg.mailbox().name();
                Mail.delete(msg);
                results.push({id: targetId, subject: subject, fromMailbox: mboxName});
            } catch(e) {
                errors.push({id: targetId, error: e.message || String(e)});
            }
        }

        JSON.stringify({results: results, errors: errors});
        """

        let raw = try runJXA(script)

        guard let dict = raw as? [String: Any] else {
            throw CLIError.jxaError("Unexpected output from batch delete")
        }

        let results = dict["results"] as? [Any] ?? []
        let errors = dict["errors"] as? [Any] ?? []

        outputJSON([
            "success": errors.isEmpty,
            "message": "Batch delete completed",
            "deleted": results,
            "deletedCount": results.count,
            "errors": errors,
            "errorCount": errors.count
        ])
    }
}

// MARK: - Send / Reply / Auth Check

struct SendMessage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send an email through Mail.app"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Recipient email address (repeatable)")
    var to: [String]

    @Option(name: .long, help: "Email subject")
    var subject: String

    @Option(name: .long, help: "Plain text body")
    var body: String

    @Option(name: .long, help: "CC email address (repeatable)")
    var cc: [String] = []

    @Option(name: .long, help: "BCC email address (repeatable)")
    var bcc: [String] = []

    @Option(name: .long, help: "Sender email address (selects account)")
    var from: String?

    @Option(name: .long, help: "File path to attach (repeatable)")
    var attachment: [String] = []

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        guard !to.isEmpty else {
            throw CLIError.invalidInput("At least one --to recipient is required")
        }

        // Validate attachment files exist before building the script
        var attachmentLines = ""
        for filePath in attachment {
            let expandedPath = (filePath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                throw CLIError.invalidInput("Attachment file not found: \(expandedPath)")
            }
            attachmentLines += "\n        make new attachment with properties {file name:\"\(escapeForAppleScript(expandedPath))\"} at after the last paragraph"
        }

        // Write body to temp file to avoid AppleScript escaping issues
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("mail-send-\(UUID().uuidString).txt")
        try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        // Build recipient lines
        var recipientLines = ""
        for addr in to {
            recipientLines += "\n        make new to recipient at end of to recipients with properties {address:\"\(escapeForAppleScript(addr))\"}"
        }
        for addr in cc {
            recipientLines += "\n        make new cc recipient at end of cc recipients with properties {address:\"\(escapeForAppleScript(addr))\"}"
        }
        for addr in bcc {
            recipientLines += "\n        make new bcc recipient at end of bcc recipients with properties {address:\"\(escapeForAppleScript(addr))\"}"
        }

        let escapedSubject = escapeForAppleScript(subject)
        let senderProp = from.map { ", sender:\"\(escapeForAppleScript($0))\"" } ?? ""

        let attachmentBlock = attachmentLines.isEmpty ? "" : """

            tell newMessage\(attachmentLines)
            end tell
        """

        let script = """
        set bodyText to read POSIX file "\(bodyFile.path)" as «class utf8»
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(escapedSubject)", visible:false\(senderProp)}
            tell newMessage\(recipientLines)
            end tell
            set content of newMessage to bodyText\(attachmentBlock)
            send newMessage
        end tell
        """

        _ = try runAppleScript(script)

        var result: [String: Any] = [
            "success": true,
            "message": "Email sent successfully",
            "to": to,
            "subject": subject
        ]
        if !attachment.isEmpty {
            result["attachments"] = attachment.map { ($0 as NSString).expandingTildeInPath }
        }
        outputJSON(result)
    }
}

struct ReplyMessage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reply",
        abstract: "Reply to a message in Mail.app"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "RFC 2822 message ID of the message to reply to")
    var id: String

    @Option(name: .long, help: "Reply body text")
    var body: String

    @Option(name: .long, help: "Mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Account name hint (speeds up lookup)")
    var account: String?

    @Option(name: .long, help: "File path to attach (repeatable)")
    var attachment: [String] = []

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        // Validate attachment files exist before building the script
        var attachmentLines = ""
        for filePath in attachment {
            let expandedPath = (filePath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                throw CLIError.invalidInput("Attachment file not found: \(expandedPath)")
            }
            attachmentLines += "\n        make new attachment with properties {file name:\"\(escapeForAppleScript(expandedPath))\"} at after the last paragraph"
        }

        // Step 1: Use JXA to find the message by RFC 2822 messageId and get its numeric Apple Mail ID
        let findHelper = findMessageJXA(targetId: id, mailbox: mailbox, account: account)
        let lookupScript = """
        \(findHelper)

        const msg = findMessage();
        if (!msg) {
            JSON.stringify({error: "Message not found: \(escapeForJXA(id))"});
        } else {
            JSON.stringify({
                appleMailId: msg.id(),
                account: msg.mailbox().account().name(),
                mailbox: msg.mailbox().name(),
                subject: msg.subject()
            });
        }
        """

        let lookupResult = try runJXA(lookupScript)

        guard let dict = lookupResult as? [String: Any] else {
            throw CLIError.jxaError("Unexpected result from message lookup")
        }

        if let error = dict["error"] as? String {
            throw CLIError.notFound(error)
        }

        guard let appleMailId = dict["appleMailId"] as? Int,
              let accountName = dict["account"] as? String,
              let mailboxName = dict["mailbox"] as? String else {
            throw CLIError.jxaError("Could not extract message details for reply")
        }
        _ = mailboxName  // retained for diagnostics; no longer used to address the message

        // Step 2: Write body to temp file
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("mail-reply-\(UUID().uuidString).txt")
        try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        // Step 3: Use AppleScript to reply using the numeric ID. The reply script
        // locates the message via a recursive mailbox-tree search rather than a
        // brittle `mailbox "<name>" of account` by-name specifier (which fails on
        // nested Gmail mailboxes with -1728). See buildReplyAppleScript / issue #67.
        let replyScript = buildReplyAppleScript(
            bodyPath: bodyFile.path,
            accountName: accountName,
            appleMailId: appleMailId,
            attachmentLines: attachmentLines
        )

        _ = try runAppleScript(replyScript)

        var result: [String: Any] = [
            "success": true,
            "message": "Reply sent successfully",
            "inReplyTo": id,
            "originalSubject": dict["subject"] ?? ""
        ]
        if !attachment.isEmpty {
            result["attachments"] = attachment.map { ($0 as NSString).expandingTildeInPath }
        }
        outputJSON(result)
    }
}

// MARK: - Save Attachment

struct SaveAttachment: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save-attachment",
        abstract: "Save one or all attachments from a message to a local directory"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "RFC 2822 message ID")
    var id: String

    @Option(name: .long, help: "Zero-based attachment index (saves all if omitted)")
    var index: Int?

    @Option(name: .long, help: "Directory to save into (default: system temp)")
    var destDir: String?

    @Option(name: .long, help: "Mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Account name hint (speeds up lookup)")
    var account: String?

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        // Phase 1: Get attachment metadata via JXA
        let findHelper = findMessageJXA(targetId: id, mailbox: mailbox, account: account)

        let metadataScript = """
        \(inferMimeJXA())

        \(findHelper)

        const msg = findMessage();
        if (!msg) {
            JSON.stringify({error: "Message not found: \(escapeForJXA(id))"});
        } else {
            var attachments = [];
            try {
                var attCount = msg.mailAttachments.length;
                for (var i = 0; i < attCount; i++) {
                    try {
                        var att = msg.mailAttachments[i];
                        attachments.push({
                            index: i,
                            name: att.name(),
                            fileSize: att.fileSize(),
                            downloaded: att.downloaded(),
                            mimeType: inferMime(att)
                        });
                    } catch(e) {}
                }
            } catch(e) {}
            JSON.stringify({attachments: attachments});
        }
        """

        let metadataRaw = try runJXA(metadataScript)

        guard let metadataDict = metadataRaw as? [String: Any] else {
            throw CLIError.jxaError("Unexpected output from attachment metadata lookup")
        }

        if let error = metadataDict["error"] as? String {
            throw CLIError.notFound(error)
        }

        let attachments = metadataDict["attachments"] as? [[String: Any]] ?? []

        guard !attachments.isEmpty else {
            throw CLIError.invalidInput("Message has no attachments")
        }

        // Determine which attachments to save
        let targetAttachments: [[String: Any]]
        if let idx = index {
            guard idx >= 0 && idx < attachments.count else {
                throw CLIError.invalidInput("Attachment index \(idx) out of range (message has \(attachments.count) attachment\(attachments.count == 1 ? "" : "s"))")
            }
            targetAttachments = [attachments[idx]]
        } else {
            targetAttachments = attachments
        }

        // Check all target attachments are downloaded
        for att in targetAttachments {
            let downloaded = att["downloaded"] as? Bool ?? false
            if !downloaded {
                let name = att["name"] as? String ?? "unknown"
                throw CLIError.invalidInput("Attachment \"\(name)\" has not been downloaded from the server yet")
            }
        }

        // Phase 2: Create destination directory and compute safe filenames
        let destDirURL: URL
        if let destDirPath = destDir {
            destDirURL = URL(fileURLWithPath: NSString(string: destDirPath).expandingTildeInPath)
        } else {
            destDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("apple-pim-attachments")
        }

        // Security: restrict writes to home directory or system temp, and reject
        // sensitive subpaths — validated *before* creating the directory so a
        // rejected target never leaves a stray directory behind.
        try validateDestDir(destDirURL)

        try FileManager.default.createDirectory(at: destDirURL, withIntermediateDirectories: true)

        // Build save targets with deduplicated filenames.
        // allocatedPaths tracks planned writes so batch saves with duplicate
        // names get unique suffixes without malformed double-numbering.
        var saveTargets = [(index: Int, destPath: String, name: String, fileSize: Int, mimeType: String)]()
        var allocatedPaths = Set<String>()

        for att in targetAttachments {
            let attIndex = att["index"] as? Int ?? 0
            let rawName = att["name"] as? String ?? ""
            let fileSize = att["fileSize"] as? Int ?? 0
            let mimeType = att["mimeType"] as? String ?? "application/octet-stream"

            let safeName = sanitizeFilename(rawName, fallback: "attachment_\(attIndex)")
            let destPath = deduplicatePath(destDirURL.appendingPathComponent(safeName).path, avoiding: allocatedPaths)
            allocatedPaths.insert(destPath)
            saveTargets.append((index: attIndex, destPath: destPath, name: safeName, fileSize: fileSize, mimeType: mimeType))
        }

        // Phase 3: Save attachments via JXA
        let findHelper2 = findMessageJXA(targetId: id, mailbox: mailbox, account: account)

        var saveStatements = ""
        for (i, target) in saveTargets.enumerated() {
            let escapedPath = escapeForJXA(target.destPath)
            saveStatements += """
            try {
                var att\(i) = msg.mailAttachments[\(target.index)];
                Mail.save(att\(i), {in: Path('\(escapedPath)')});
                saved.push({index: \(target.index), path: '\(escapedPath)', success: true});
            } catch(e) {
                errors.push({index: \(target.index), error: e.message || String(e)});
            }

            """
        }

        let saveScript = """
        \(findHelper2)

        const Mail = Application("Mail");
        const msg = findMessage();
        if (!msg) {
            JSON.stringify({error: "Message not found on second lookup"});
        } else {
            var saved = [];
            var errors = [];
            \(saveStatements)
            JSON.stringify({saved: saved, errors: errors});
        }
        """

        let saveRaw = try runJXA(saveScript)

        guard let saveDict = saveRaw as? [String: Any] else {
            throw CLIError.jxaError("Unexpected output from attachment save")
        }

        if let error = saveDict["error"] as? String {
            throw CLIError.jxaError(error)
        }

        let savedResults = saveDict["saved"] as? [[String: Any]] ?? []
        let saveErrors = saveDict["errors"] as? [[String: Any]] ?? []

        // Build final response with full metadata and post-save size verification
        var savedOutput = [[String: Any]]()
        for result in savedResults {
            guard let resultIndex = result["index"] as? Int,
                  let path = result["path"] as? String else { continue }
            if let target = saveTargets.first(where: { $0.index == resultIndex }) {
                var entry: [String: Any] = [
                    "index": resultIndex,
                    "name": target.name,
                    "path": path,
                    "fileSize": target.fileSize,
                    "mimeType": target.mimeType
                ]
                // Verify saved file size matches expected (catches deferred/stub downloads)
                let actualSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                if actualSize == 0 && target.fileSize > 0 {
                    entry["warning"] = "Saved file is empty (attachment may not have been fully downloaded)"
                }
                savedOutput.append(entry)
            }
        }

        if !saveErrors.isEmpty {
            outputJSON([
                "success": false,
                "saved": savedOutput,
                "errors": saveErrors
            ])
        } else {
            outputJSON([
                "success": true,
                "saved": savedOutput
            ])
        }
    }

    private func sanitizeFilename(_ name: String, fallback: String) -> String {
        var sanitized = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespaces)

        while sanitized.hasPrefix(".") {
            sanitized = String(sanitized.dropFirst())
        }

        if sanitized.isEmpty {
            return fallback
        }

        return sanitized
    }

    /// Find a unique path by appending _1, _2, etc. before the extension.
    /// Checks both disk and the `avoiding` set so batch saves with duplicate
    /// names get clean suffixes (report_1.pdf, report_2.pdf) not garbled ones.
    private func deduplicatePath(_ path: String, avoiding: Set<String> = []) -> String {
        func isTaken(_ p: String) -> Bool {
            avoiding.contains(p) || FileManager.default.fileExists(atPath: p)
        }

        guard isTaken(path) else { return path }

        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().path
        let ext = url.pathExtension
        let stem: String
        if ext.isEmpty {
            stem = url.lastPathComponent
        } else {
            stem = String(url.lastPathComponent.dropLast(ext.count + 1))
        }

        for i in 1...99 {
            let candidate: String
            if ext.isEmpty {
                candidate = "\(directory)/\(stem)_\(i)"
            } else {
                candidate = "\(directory)/\(stem)_\(i).\(ext)"
            }
            if !isTaken(candidate) {
                return candidate
            }
        }

        let ts = Int(Date().timeIntervalSince1970)
        if ext.isEmpty {
            return "\(directory)/\(stem)_\(ts)"
        } else {
            return "\(directory)/\(stem)_\(ts).\(ext)"
        }
    }
}

// MARK: - Auth Check

/// Trusted sender entry from trusted-senders.json
private struct TrustedSender: Decodable {
    let name: String
    let emails: [String]
    let expectedDkimDomains: [String]?
    let requireDkim: Bool?
    let requireSpf: Bool?
}

private struct TrustedSendersFile: Decodable {
    let version: Int?
    let trustedSenders: [TrustedSender]
}

/// Parsed DKIM result from Authentication-Results header
private struct DKIMResult {
    let result: String  // "pass", "fail", "none", etc.
    let signingDomain: String
    let selector: String?
}

/// Parsed SPF result
private struct SPFResult {
    let result: String
    let mailFrom: String?
}

/// Parsed Authentication-Results header
private struct AuthResult {
    let authservId: String
    let dkim: [DKIMResult]
    let spf: SPFResult?
}

struct AuthCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth-check",
        abstract: "Verify email sender authentication (DKIM + SPF)"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "RFC 2822 message ID")
    var id: String

    @Option(name: .long, help: "Path to trusted-senders.json (default: ~/.config/apple-pim/trusted-senders.json)")
    var trustedSenders: String?

    @Option(name: .long, help: "Mailbox name hint (speeds up lookup)")
    var mailbox: String?

    @Option(name: .long, help: "Account name hint (speeds up lookup)")
    var account: String?

    func run() async throws {
        try ensureMailRunning()
        let config = pimOptions.loadConfig()
        try checkMailEnabled(config: config)

        // Load trusted senders
        let trustedPath = trustedSenders ?? NSString("~/.config/apple-pim/trusted-senders.json").expandingTildeInPath
        let trustedFile: TrustedSendersFile
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: trustedPath))
            trustedFile = try JSONDecoder().decode(TrustedSendersFile.self, from: data)
        } catch {
            outputJSON([
                "verdict": "unknown",
                "sender": "",
                "matchedContact": "",
                "checks": [String: Any](),
                "warnings": ["Failed to load trusted-senders.json: \(error.localizedDescription)"]
            ])
            return
        }

        // Fetch message with allHeaders via JXA
        let findHelper = findMessageJXA(targetId: id, mailbox: mailbox, account: account)
        let script = """
        \(findHelper)

        const msg = findMessage();
        if (!msg) {
            JSON.stringify({error: "Message not found: \(escapeForJXA(id))"});
        } else {
            const result = {
                sender: msg.sender(),
                subject: msg.subject()
            };
            try {
                result.allHeaders = msg.allHeaders();
            } catch(e) {}
            JSON.stringify(result);
        }
        """

        let raw = try runJXA(script)

        guard let msgDict = raw as? [String: Any] else {
            throw CLIError.jxaError("Unexpected result from message lookup")
        }

        if let error = msgDict["error"] as? String {
            throw CLIError.notFound(error)
        }

        // Extract sender email
        let senderRaw = msgDict["sender"] as? String ?? ""
        let senderEmail = extractEmailAddress(from: senderRaw)

        guard !senderEmail.isEmpty else {
            outputJSON([
                "verdict": "unknown",
                "sender": "",
                "matchedContact": "",
                "checks": [String: Any](),
                "warnings": ["Could not extract sender email from message"]
            ])
            return
        }

        // Look up trusted sender
        let senderConfig = trustedFile.trustedSenders.first { sender in
            sender.emails.contains { $0.lowercased() == senderEmail }
        }

        guard let senderConfig = senderConfig else {
            outputJSON([
                "verdict": "untrusted",
                "sender": senderEmail,
                "matchedContact": "",
                "checks": [String: Any](),
                "warnings": ["Sender \(senderEmail) not in trusted-senders.json"]
            ])
            return
        }

        // Get allHeaders
        let headerText = normalizeHeaders(msgDict["allHeaders"])

        guard !headerText.isEmpty else {
            outputJSON([
                "verdict": "unknown",
                "sender": senderEmail,
                "matchedContact": senderConfig.name,
                "checks": [String: Any](),
                "warnings": ["allHeaders field is empty — JXA may not have returned headers"]
            ])
            return
        }

        // Parse Authentication-Results
        let authResults = parseAuthenticationResults(headerText)

        guard !authResults.isEmpty else {
            outputJSON([
                "verdict": "unknown",
                "sender": senderEmail,
                "matchedContact": senderConfig.name,
                "checks": [String: Any](),
                "warnings": ["No Authentication-Results headers found"]
            ])
            return
        }

        // Evaluate
        let expectedDkim = senderConfig.expectedDkimDomains ?? []
        let requireDkim = senderConfig.requireDkim ?? true
        let requireSpf = senderConfig.requireSpf ?? true
        var warnings = [String]()

        // Aggregate DKIM results from all AR headers
        let allDkim = authResults.flatMap { $0.dkim }
        // Aggregate SPF — pick first non-nil
        let aggregatedSpf = authResults.compactMap { $0.spf }.first

        let anyDkimPass = allDkim.contains { $0.result == "pass" }
        let matchingDkim = allDkim.filter { $0.result == "pass" && checkDkimDomain($0.signingDomain, expected: expectedDkim) }
        let allSigningDomains = allDkim.map { $0.signingDomain }

        // Build DKIM check report
        var dkimCheck: [String: Any]
        if let best = matchingDkim.first {
            dkimCheck = ["result": "pass", "signingDomain": best.signingDomain, "expected": expectedDkim, "match": true, "allSigningDomains": allSigningDomains]
        } else if anyDkimPass {
            let firstPass = allDkim.first { $0.result == "pass" }!
            dkimCheck = ["result": "pass", "signingDomain": firstPass.signingDomain, "expected": expectedDkim, "match": false, "allSigningDomains": allSigningDomains]
            warnings.append("DKIM passed but no signing domain in \(allSigningDomains) matches expected \(expectedDkim)")
        } else if let first = allDkim.first {
            dkimCheck = ["result": first.result, "signingDomain": first.signingDomain, "expected": expectedDkim, "match": false, "allSigningDomains": allSigningDomains]
        } else {
            dkimCheck = ["result": "none", "signingDomain": "", "expected": expectedDkim, "match": false, "allSigningDomains": [String]()]
        }

        // Build SPF check report
        var spfCheck: [String: Any] = ["result": "none", "match": false]
        if let spf = aggregatedSpf {
            spfCheck["result"] = spf.result
            spfCheck["match"] = spf.result == "pass"
        }

        // Determine verdict
        let dkimPass = (dkimCheck["result"] as? String) == "pass"
        let dkimDomainOk = (dkimCheck["match"] as? Bool) ?? false
        let spfPass = (spfCheck["result"] as? String) == "pass"

        let verdict: String
        if dkimPass && dkimDomainOk && spfPass {
            verdict = "verified"
        } else if dkimPass && dkimDomainOk && !requireSpf {
            verdict = "verified"
            if !spfPass { warnings.append("SPF result is '\(spfCheck["result"] ?? "none")' but not required for this sender") }
        } else if spfPass && !requireDkim {
            verdict = "verified"
            if !dkimPass { warnings.append("DKIM result is '\(dkimCheck["result"] ?? "none")' but not required for this sender") }
        } else {
            verdict = "suspicious"
            if requireDkim && !dkimPass {
                warnings.append("DKIM required but result is '\(dkimCheck["result"] ?? "none")'")
            }
            if requireDkim && dkimPass && !dkimDomainOk {
                warnings.append("DKIM passed but signing domain mismatch — possible spoofing")
            }
            if requireSpf && !spfPass {
                warnings.append("SPF required but result is '\(spfCheck["result"] ?? "none")'")
            }
        }

        outputJSON([
            "verdict": verdict,
            "sender": senderEmail,
            "matchedContact": senderConfig.name,
            "checks": [
                "dkim": dkimCheck,
                "spf": spfCheck
            ],
            "warnings": warnings
        ])
    }

    // MARK: - Private Helpers

    /// Extract email address from a "Name <email>" or bare email string.
    private func extractEmailAddress(from raw: String) -> String {
        // Try "Name <email>" format
        if let range = raw.range(of: #"<([^>]+)>"#, options: .regularExpression) {
            let match = raw[range]
            return String(match.dropFirst().dropLast()).lowercased().trimmingCharacters(in: .whitespaces)
        }
        // Bare email
        if raw.contains("@") {
            return raw.lowercased().trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// Normalize allHeaders from JXA (could be dict or string) into a single string.
    private func normalizeHeaders(_ raw: Any?) -> String {
        if let str = raw as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return str
        }
        if let dict = raw as? [String: Any] {
            var lines = [String]()
            for (key, value) in dict {
                if let arr = value as? [String] {
                    for v in arr {
                        lines.append("\(key): \(v)")
                    }
                } else {
                    lines.append("\(key): \(value)")
                }
            }
            return lines.joined(separator: "\n")
        }
        return ""
    }

    /// Parse Authentication-Results headers from header text.
    private func parseAuthenticationResults(_ headerText: String) -> [AuthResult] {
        var results = [AuthResult]()

        // Unfold continuation lines
        let unfolded = headerText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)

        for line in unfolded.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("authentication-results:") else { continue }

            let value = String(trimmed.dropFirst("authentication-results:".count)).trimmingCharacters(in: .whitespaces)
            let parts = value.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }

            let authservId = parts.first ?? ""
            var dkimResults = [DKIMResult]()
            var spfResult: SPFResult? = nil

            for part in parts.dropFirst() {
                let trimPart = part.trimmingCharacters(in: .whitespaces)
                guard !trimPart.isEmpty else { continue }

                // Parse dkim=
                if let dkimMatch = trimPart.range(of: #"dkim\s*=\s*(\w+)"#, options: [.regularExpression, .caseInsensitive]) {
                    let resultStr = extractRegexGroup(trimPart, pattern: #"dkim\s*=\s*(\w+)"#)?.lowercased() ?? "none"
                    let domain = extractRegexGroup(trimPart, pattern: #"header\.d\s*=\s*([\w.\-]+)"#)?.lowercased() ?? ""
                    let selector = extractRegexGroup(trimPart, pattern: #"header\.s\s*=\s*([\w.\-]+)"#)
                    dkimResults.append(DKIMResult(result: resultStr, signingDomain: domain, selector: selector))
                    _ = dkimMatch // suppress unused warning
                }

                // Parse spf=
                if let spfMatch = trimPart.range(of: #"spf\s*=\s*(\w+)"#, options: [.regularExpression, .caseInsensitive]) {
                    let resultStr = extractRegexGroup(trimPart, pattern: #"spf\s*=\s*(\w+)"#)?.lowercased() ?? "none"
                    let mailFrom = extractRegexGroup(trimPart, pattern: #"smtp\.mailfrom\s*=\s*([\w@.\-]+)"#)?.lowercased()
                    spfResult = SPFResult(result: resultStr, mailFrom: mailFrom)
                    _ = spfMatch
                }
            }

            results.append(AuthResult(authservId: authservId, dkim: dkimResults, spf: spfResult))
        }

        return results
    }

    /// Extract first capture group from a regex pattern.
    private func extractRegexGroup(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Check if a signing domain matches any expected domain (exact or subdomain).
    private func checkDkimDomain(_ signing: String, expected: [String]) -> Bool {
        for domain in expected {
            let d = domain.lowercased()
            if signing == d || signing.hasSuffix("." + d) {
                return true
            }
        }
        return false
    }
}

// MARK: - Config Command

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage PIM configuration",
        subcommands: [ConfigShow.self]
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Display the resolved configuration (base + profile)"
    )

    @OptionGroup var pimOptions: PIMOptions

    func run() throws {
        let config = pimOptions.loadConfig()
        let ctx = pimOptions.outputContext
        let activeProfile = pimOptions.profile ?? ProcessInfo.processInfo.environment["APPLE_PIM_PROFILE"]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        pimOutput(
            [
                "success": true,
                "configPath": ConfigLoader.defaultConfigPath.path,
                "profilesDir": ConfigLoader.profilesDir.path,
                "activeProfile": activeProfile as Any,
                "config": (try? JSONSerialization.jsonObject(with: data)) ?? [:]
            ],
            text: ConfigFormatter.formatConfigShow(
                config: config,
                configPath: ConfigLoader.defaultConfigPath.path,
                profilesDir: ConfigLoader.profilesDir.path,
                activeProfile: activeProfile
            ),
            context: ctx
        )
    }
}
