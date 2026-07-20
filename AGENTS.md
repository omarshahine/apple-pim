# Apple PIM Plugin

macOS PIM (Personal Information Management) tools for Calendar, Reminders, Contacts, and Mail.app. Works with Claude Code (via MCP) and OpenClaw (via native tool registration). Both adapters share a common `lib/` layer that delegates to native Swift CLIs using EventKit, Contacts framework, and JXA.

## Quick Commands

```bash
# Initial setup
./setup.sh

# Swift CLIs
cd swift
swift build -c release
swift test

# MCP server
cd mcp-server
npm install
npm test
npm run build

# Agent evals (from repo root)
npm run eval
```

## Architecture

Handler logic, schemas, and sanitization live in `lib/` (shared). The MCP server and OpenClaw plugin are thin adapters. All access control, filtering, and default resolution is handled by the Swift CLIs via the shared `PIMConfig` library:

```
Claude Code  <--MCP-->  mcp-server/server.js  ---+
                                                  +--> lib/ (handlers, schemas, sanitize)
OpenClaw  <--tools-->  openclaw/src/index.ts  ---+           |
                                                        Swift CLIs (EventKit / Contacts / JXA)
                                                             |
                                                        PIMConfig (~/.config/apple-pim/)
```

Each Swift CLI is a standalone binary that reads from macOS frameworks, validates access via PIMConfig, and writes JSON to stdout.

## Repo Layout

| Path | Purpose |
|------|---------|
| `lib/` | Shared handler logic, schemas, sanitize (used by both MCP and OpenClaw) |
| `lib/handlers/` | Domain handlers: calendar, reminder, contact, mail, apple-pim |
| `swift/Sources/PIMConfig` | Shared config library (filtering, profiles, validation) |
| `swift/Sources/CalendarCLI` | EventKit calendar CLI |
| `swift/Sources/ReminderCLI` | EventKit reminders CLI |
| `swift/Sources/ContactsCLI` | Contacts framework CLI |
| `swift/Sources/MailCLI` | Mail.app JXA-based CLI |
| `mcp-server/server.js` | MCP adapter (imports lib/, thin pass-through) |
| `mcp-server/dist/server.js` | Bundled server artifact (rebuild after source changes) |
| `openclaw/` | OpenClaw plugin package (NPM: apple-pim-cli) |
| `openclaw/src/index.ts` | OpenClaw tool registration with per-call isolation |
| `evals/` | Agent eval suite (YAML scenarios, JSON fixtures, vitest tests) |
| `evals/helpers/` | Mock CLI runner, scenario loader, grading functions |
| `evals/fixtures/` | Canned CLI JSON responses for deterministic testing |
| `evals/scenarios/` | YAML eval case definitions (4 categories) |
| `evals/tests/` | Vitest test files (tool-call, response, multi-turn, safety) |
| `.github/workflows/tests.yml` | CI checks for Node, Swift, and agent eval jobs |

## Configuration (PIMConfig)

- Config lives at `~/.config/apple-pim/config.json` (base) with optional profiles at `~/.config/apple-pim/profiles/{name}.json`.
- All four CLIs share the `PIMConfig` library for allowlist/blocklist filtering, domain enable/disable, and defaults.
- Profile selection: `--profile` flag > `APPLE_PIM_PROFILE` env var > base config only.
- **Fail-closed profiles:** If a profile is explicitly requested (via `--profile` or `APPLE_PIM_PROFILE`) but the file doesn't exist, the CLI exits with an error instead of falling back to the base config.
- Profile overrides replace entire domain sections (not field-by-field merge).
- The MCP server does NOT do any config filtering — it passes `--profile` to CLIs when set.
- **OpenClaw plugin** (`openclaw/`): Registers tools that spawn CLIs directly (no MCP). Supports per-call `configDir`/`profile` parameters for multi-agent workspace isolation. See [`docs/multi-agent-setup.md`](docs/multi-agent-setup.md).
- **Direct CLI usage:** `APPLE_PIM_CONFIG_DIR` overrides the config root directory; `APPLE_PIM_PROFILE` selects a profile.
- **Date format:** `APPLE_PIM_DATE_FORMAT` selects calendar date output format. Presets: `utc` (default, `2026-03-20T14:00:00Z`), `local` (`2026-03-20T07:00:00-07:00`), `day-utc` (`Friday, 2026-03-20T14:00:00Z`), `day-local` (`Friday, 2026-03-20T07:00:00-07:00`). CalendarCLI only.

## Testing Notes

- Keep pure parsing/argument mapping logic extractable and unit tested.
- PIMConfig tests (`swift/Tests/PIMConfigTests/`) cover filtering logic, config round-trips, profile merging, and security validation.
- Prefer unit tests for logic seams (`swift/Tests/*`, `mcp-server/test/*`) over tests that require macOS permissions.
- Full EventKit/Contacts/Mail integration paths can require local TCC permissions and Mail.app running.
- **Agent evals** (`evals/`) test the tool layer from the agent's perspective: argument correctness, response interpretation, multi-turn workflows, and safety properties. All evals run against mock CLI fixtures (zero TCC, no real data). Run with `npm run eval` from repo root.
- To add new eval cases, edit the YAML files in `evals/scenarios/` and add fixture JSON in `evals/fixtures/` as needed. No test code changes required for new cases in existing categories.
- **Calendar reasoning evals** (`tests/calendar-reasoning.test.js`) are model-in-the-loop: they call `claude -p` with fixtures and grade responses with an LLM judge. They require `ANTHROPIC_API_KEY` in the environment. A full run of 8 scenarios costs ~$2.31 and takes ~8 minutes. These are non-deterministic and may flake on edge-case reasoning.

## CI And PR Workflow

- Required checks on `main`:
  - `MCP Server (Node)`
  - `Swift CLI`
  - `Agent Evals`
- Auto-merge is enabled at the repo level; use it on PRs so merges wait for required checks.
- This repo ignores lockfiles; CI uses `npm install` (not `npm ci`) in `mcp-server`.
- Agent evals run on `ubuntu-latest` (no macOS needed since they use mock fixtures).

## Code Hygiene

- No hardcoded user paths (`/Users/[name]/`) - use `~/` or `${HOME}`
- No personal email addresses in tracked files (allowed: `@example.com`, `@anthropic.com`, `@noreply`)
- No API keys or secrets in code - use environment variables
- No phone numbers or PII in examples - use generic placeholders

## Versioning

All five version sources must agree, plus the matching GitHub release tag:

| Source | File | jq path |
|--------|------|---------|
| Claude Code plugin | `.claude-plugin/plugin.json` | `.version` |
| Claude Code marketplace | `.claude-plugin/marketplace.json` | `.plugins[0].version` |
| MCP server | `mcp-server/package.json` | `.version` |
| OpenClaw plugin | `openclaw/package.json` | `.version` |
| OpenClaw manifest | `openclaw/openclaw.plugin.json` | `.version` |
| GitHub release | tag (e.g., `v3.7.1`) | — |

**Canonical bump path** (rewrites all five files atomically and rebuilds the MCP bundle):

```bash
scripts/bump-version.sh 3.7.2
```

**Verify consistency** (CI runs the same check via the composite action `omarshahine/version-consistency-action@v1` as the `Version Consistency` required check):

```bash
scripts/check-versions.sh
```

After bumping: commit, tag `v<new>`, push. CI enforces agreement on every PR — a drifted manifest will fail the `Version Consistency` job.

## Publishing (OpenClaw Plugin)

The OpenClaw plugin is published as `apple-pim-cli` on both ClawHub and NPM.

### Automated (CI)

ClawHub publishing is automated via GitHub Actions (`.github/workflows/publish-clawhub.yml`). To publish a new version:

```bash
# 1. Follow the publishing checklist below
# 2. Commit and push
# 3. Tag and push the tag
git tag -a v3.1.0 -m "Description of changes"
git push origin v3.1.0
```

The workflow extracts the version from the tag name and the changelog from the tag annotation. Authenticates with the `CLAWHUB_TOKEN` repository secret.

**Note**: The CI workflow runs `npm run prepack` in `openclaw/` to resolve the `lib/` symlink into a real directory copy before publishing. This mirrors what the manual script does.

### Manual (fallback)

```bash
./publish-clawhub.sh --changelog "description of changes"
```

The script handles prepack/postpack automatically (copies `lib/` from symlink to real directory, publishes, then restores the symlink). Requires `clawhub` CLI installed and authenticated.

### NPM (fallback)

```bash
cd openclaw
npm publish
# Requires NPM login (npm login) and browser 2FA confirmation
```

- `prepack` script copies `lib/` from symlink into a real directory; `postpack` restores the symlink
- `publishConfig.access: "public"` ensures public access by default

### Publishing checklist

1. Bump version in both `openclaw/package.json` and `mcp-server/package.json`
2. Update `version` in `openclaw/openclaw.plugin.json` to match
3. Rebuild `mcp-server/dist/server.js`
4. Commit, merge to main, tag the GitHub release
5. ClawHub publishes automatically via CI on tag push (or use manual script)

### Verify / Install

```bash
clawhub package inspect apple-pim-cli
openclaw plugins install apple-pim-cli
```

## Gotchas

- `mcp-server/dist/server.js` is generated; rebuild it after editing `lib/` or `mcp-server/` source files.
- OpenClaw loads TypeScript directly — no build step needed after editing `openclaw/` or `lib/`.
- Mail features depend on Mail.app being open and Automation permissions being granted.
- `lib/` has shared deps (`mailparser`, `turndown`) installed at the repo root `package.json`. Run `npm install` at root after cloning.
- **Plugin cache must include `.claude-plugin/`**: When installed via a marketplace, the `.claude-plugin/plugin.json` (which defines `mcpServers`) must be present in the cache. If missing, the MCP server won't start and tools won't register. Verify: `ls ~/.claude/plugins/cache/*/apple-pim/*/.claude-plugin/plugin.json`
- **Subagent hallucination risk**: If the MCP server is not running, subagents told they have `mcp__plugin_apple-pim_apple-pim__*` tools will silently hallucinate results instead of erroring. The `pim-assistant` agent has a mandatory preflight check. Callers should prefer direct MCP tool calls or the Swift CLI over subagents.
## Claude Code GitHub Actions

This repo uses Claude Code GitHub Actions for PR automation:

- **`claude.yml`** - Responds to `@claude` mentions in PR/issue comments

Auto code review is handled by **Greptile**, not Claude Code. Use `@greptile review` in a PR comment to trigger a re-review after pushing fixes.

## Clawpatch Code Review

This repo uses [Clawpatch](https://clawpatch.ai) for local automated code review. Keep `.clawpatch/` ignored; it is generated runtime state containing features, findings, reports, runs, and patch attempts.

Standard workflow:

```bash
clawpatch doctor
clawpatch init          # first time only
clawpatch map
clawpatch review --limit 10
clawpatch report --output .clawpatch/reports/summary.md
clawpatch show --finding <id>
clawpatch fix --finding <id>
clawpatch revalidate --finding <id>
```

If this repo needs hand-authored feature coverage, keep those curated definitions in `tools/clawpatch/features/` and sync/copy them into `.clawpatch/features/` before review. Do not commit `.clawpatch/` generated state.


<!-- BEGIN CLAUDE MEMORY IMPORT: -Users-omarshahine-GitHub-apple-pim -->
## Imported Claude Project Memory

Durable memory promoted from `~/.claude/projects/-Users-omarshahine-GitHub-apple-pim/memory` during the AGENTS.md migration. Keep this section current when project-specific operating knowledge changes.

### memory/MEMORY.md

# Apple PIM Agent Plugin - Memory

## Architecture
- Swift CLIs (`calendar-cli`, `reminder-cli`, `contacts-cli`, `mail-cli`) live in `swift/Sources/`
- Shared handler logic, schemas, sanitize in `lib/` — used by both MCP server and OpenClaw plugin
- Handlers receive `runCLI` via dependency injection (second parameter)
- MCP adapter in `mcp-server/server.js` imports from `lib/`, thin pass-through
- OpenClaw plugin in `openclaw/src/index.ts` — registers 5 `apple_pim_*` tools with per-call env isolation
- `openclaw/lib` is a symlink to `../lib`; `prepack`/`postpack` scripts handle npm publishing
- Root `package.json` has shared deps (`mailparser`, `turndown`) for `lib/` resolution
- Agent at `agents/pim-assistant.md`, skill at `skills/apple-pim/SKILL.md`
- CalendarCLI and ReminderCLI share identical helper functions (ruleToDict, parseRecurrenceRule, etc) - changes to one must be mirrored in the other
- MailCLI reads (accounts/mailboxes/messages/get/search) default to a direct read-only SQLite engine over Mail's Envelope Index (`EnvelopeIndex.swift`/`SQLiteEngine.swift`, needs Full Disk Access, works with Mail closed) with silent JXA fallback; mutations/sends and `content` search use JXA/AppleScript via `osascript -l JavaScript` — no native Swift framework for Mail.app

## Key Patterns
- `RecurrenceJSON.frequency` is `String?` (optional) — `nil` or `"none"` means remove recurrence
- `DeleteEvent` and `UpdateEvent` both support `--future-events` flag for EKSpan control
- `ruleToDict()` outputs `daysOfTheWeek` and `daysOfTheMonth` from recurrence rules
- MCP server passes `--future-events` CLI flag when `args.futureEvents` is true

## Mail CLI Patterns
- JXA batch `.slice()` on property arrays can fail with -1700 ("Can't convert types") on null dates — use per-message access with try/catch instead
- `findMessage()` uses priority mailbox search (INBOX, Sent, Archive, etc.) before full scan
- ID-based commands (`get`, `update`, `move`, `delete`) accept optional `--mailbox`/`--account` hints for fast lookup
- Message ID is RFC 2822 `messageId` (stable across moves), not Mail.app internal ID
- Mail.app must be running — checked via `NSWorkspace.shared.runningApplications`
- 30-second timeout on JXA execution

## Subtask/Parent Relationships (DOES NOT WORK)
- `EKReminder` has undocumented KVC: `parentID` (type `EKObjectID`), `setParentID:`, `clearParentID`
- Writing broken: setValue works in memory but NOT through `eventStore.save()` — doesn't persist on refetch
- `parentID` is typed `EKObjectID` (internal), not `String` — even with correct type, save doesn't serialize
- AppleScript `container` property is read-only — assignment fails with "Can't set that"
- All EKObjectIDs come back as temporary (`isTemporary: true`) — no way to get persistent IDs
- No programmatic way to create/modify subtask relationships. Only Reminders.app UI can do this.

## Build
- `cd swift && swift build -c release` compiles all 4 CLIs
- Binaries at `swift/.build/release/{calendar-cli,reminder-cli,contacts-cli,mail-cli}`

## Feedback memories
- [Push vs PR disambiguation](feedback_push_vs_pr.md) — "push" does not automatically mean open a PR; clarify when ambiguous
- [Mail attachment policy is default-deny](feedback_attachment_exfil_defense.md) — `lib/safe-attachments.js` is opt-in only; don't loosen the default or weaken the hard denylist

## Project memories
- [TCC helper app](project_tcc_helper_app.md) — `helper/` + `PIMHelper.app` is the durable fix for macOS TCC responsible-process attribution; `lib/cli-runner.js` auto-routes Calendar/Reminders/Contacts through it

### memory/feedback_attachment_exfil_defense.md

---
name: Mail attachment policy is default-deny
description: Mail send/reply attachment paths are default-denied via lib/safe-attachments.js. Opt-in only. Don't loosen this without thinking through the exfiltration vector again.
type: feedback
originSessionId: 24c4c04e-e18d-4915-ba66-e595a7519903
---
`lib/handlers/mail.js` `send` and `reply` actions used to accept arbitrary
attachment paths with `~/` expansion (only checked existsSync). ClawHub
security review (v3.7.16/17) correctly flagged this as a Local File
Exfiltration channel — a prompt-injected agent could attach
`~/.ssh/id_rsa` to an outbound email.

**Why:** prompt injection is the threat model for any LLM-driven email
sender. The agent does not need free file-system reads via the mail
attachment path. The user attaching a file is the rare case; closing
the exfil channel by default is the right tradeoff.

**How to apply:**
- Don't replace the default-deny with a default-allow (e.g. "allow
  ~/Downloads out of the box"). The whole point is that the user must
  opt in by writing a config file — that single act establishes consent.
- Hard denylist (.ssh, .aws, id_rsa, *.pem, *secret*, etc.) always wins
  over `allowedRoots`, even if the user explicitly listed an allowed
  root that contains those. Don't add a "but the user said so" override.
- Always `realpathSync` both the candidate path and `allowedRoots`
  before comparing — symlinks and `..` traversal are how this gets
  bypassed. macOS `/var` ↔ `/private/var` symlink will silently break
  the comparison if you skip canonicalization.
- If you ever add a new mail action that touches local files (e.g. a
  hypothetical "attach screenshot" or "import from disk"), route it
  through `validateAttachments` from the same module rather than
  re-implementing the check.

### memory/feedback_push_vs_pr.md

---
name: "push" does not automatically mean "open a PR"
description: When Omar says "push" after a commit/PR options prompt, clarify with AskUserQuestion rather than defaulting to the full PR workflow.
type: feedback
originSessionId: cf9ab848-dc89-497f-a827-ad9666dbba6c
---
When Omar says "push" (especially as a one-word reply), he usually means `git push`, not "open a PR." Don't auto-invoke `/git-pr` or `/commit-push-pr` unless he explicitly names the PR or uses a phrase like "open a PR" or "ship it."

**Why:** On 2026-04-19 I offered three options (`/git-pr`, `/commit`, leave uncommitted) and he replied "push." I chose `/git-pr`, which committed, pushed, opened a branch, created PR #17, and scheduled Greptile polling. His correction: "I did not ask you to make a PR."

**How to apply:** When a reply could reasonably mean "git push" OR "open a PR," use AskUserQuestion to disambiguate between: (a) commit + push to current branch, (b) commit + push to main, (c) open a PR. Also reinforces the CLAUDE.md rule "ALWAYS ask before committing or pushing."

### memory/project_tcc_helper_app.md

---
name: tcc-helper-app
description: "PIMHelper.app is the durable workaround for macOS TCC's responsible-process attribution when the Swift CLIs are spawned by an embedded shell that has no Calendar/Reminders/Contacts TCC entry (e.g. Clawpilot)."
metadata: 
  node_type: memory
  type: project
  originSessionId: 6d16d518-5726-4838-8a45-de7839764276
---

The plugin ships an in-repo helper at `helper/` (Info.plist + `pim-helper` zsh dispatcher). `scripts/build-helper-app.sh` assembles it into `~/Applications/PIMHelper.app` (overridable via `APPLE_PIM_HELPER_APP`), ad-hoc signs it, and lsregisters it. `setup.sh --install` runs the installer.

`lib/cli-runner.js` auto-detects: on first call to each Calendar / Reminders / Contacts CLI it probes `auth-status` directly; if `notDetermined` or `denied` AND the helper exists, it caches `route=helper` for that CLI for the remainder of the process. Helper invocations go through `/usr/bin/open -W -a PIMHelper.app --args <cli> <out> <err> <args...>` with `APPLE_PIM_BIN_DIR` exported so the dispatcher can find the CLI binary.

**Why:** macOS TCC attributes Calendar / Reminders / Contacts permissions to the *responsible process* — the LaunchServices-launched app, not the binary that calls EventKit / Contacts. When an embedded agent shell spawns the CLI as a child, the shell is the responsible process; EventKit returns `notDetermined`/`denied` without ever surfacing a prompt. Wrapping the CLI in an ad-hoc-signed .app and invoking it via `open -W` makes the .app its own responsible process; the prompt fires against the helper's bundle id (`com.omarshahine.apple-pim.helper`) and the grant persists.

**How to apply:** Mail.app is intentionally NOT routed through the helper — it uses Automation TCC, a different service. If a new EventKit/Contacts CLI is added, list it in `HELPER_ELIGIBLE_CLIS` in `lib/cli-runner.js` and add the corresponding usage string to `helper/Info.plist`. Do not bind Info.plist into the CLI Mach-O via linker `-sectcreate` — empirically tested, doesn't fix the responsible-process attribution. Related: see [[feedback_push_vs_pr]] for unrelated push/PR convention; nothing else cross-references yet.

<!-- END CLAUDE MEMORY IMPORT: -Users-omarshahine-GitHub-apple-pim -->
