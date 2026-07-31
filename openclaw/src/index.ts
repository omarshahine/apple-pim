/**
 * OpenClaw plugin entry for Apple PIM CLI Tools.
 *
 * Registers 5 tool factories that spawn the Swift CLIs directly (no MCP server).
 * Uses the factory pattern so each agent gets per-workspace config resolution.
 * Supports per-call environment isolation via configDir/profile parameters
 * and automatic workspace convention discovery.
 */

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { appleMailChannelEntry } from "./mail-channel/entry.js";
import {
  describeSendApproval,
  evaluateSend,
  resolveSendEgressPolicy,
} from "./mail-channel/send-approval.js";
import { createCLIRunner, findSwiftBinDir } from "../lib/cli-runner.js";
import { tools } from "../lib/schemas.js";
import { markToolResult, getDatamarkingPreamble } from "../lib/sanitize.js";
import { withAgentDX } from "../lib/agent-dx.js";
import { handleCalendar } from "../lib/handlers/calendar.js";
import { handleReminder } from "../lib/handlers/reminder.js";
import { handleContact } from "../lib/handlers/contact.js";
import { handleMail } from "../lib/handlers/mail.js";
import { handleApplePim } from "../lib/handlers/apple-pim.js";
import { existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

// Plugin config (set by the gateway from openclaw.plugin.json configSchema)
interface PluginConfig {
  binDir?: string;
  profile?: string;
  configDir?: string;
  mailAttachmentsConfig?: string;
}

// Tool args always include optional isolation params
interface ToolArgs {
  action: string;
  configDir?: string;
  profile?: string;
  [key: string]: unknown;
}

// Map MCP tool names to OpenClaw snake_case names
const TOOL_NAME_MAP: Record<string, string> = {
  "calendar": "apple_pim_calendar",
  "reminder": "apple_pim_reminder",
  "contact": "apple_pim_contact",
  "mail": "apple_pim_mail",
  "apple-pim": "apple_pim_system",
};

// Map MCP tool names to handler functions (wrapped with agent DX features)
const HANDLERS: Record<string, (args: ToolArgs, runCLI: (cli: string, args: string[]) => Promise<object>) => Promise<object>> = {
  "calendar": withAgentDX("calendar", handleCalendar) as typeof handleCalendar,
  "reminder": withAgentDX("reminder", handleReminder) as typeof handleReminder,
  "contact": withAgentDX("contact", handleContact) as typeof handleContact,
  "mail": withAgentDX("mail", handleMail) as typeof handleMail,
  "apple-pim": withAgentDX("apple-pim", handleApplePim) as typeof handleApplePim,
};

/**
 * Resolve the binary directory using a discovery chain:
 * 1. Plugin config binDir
 * 2. Env var APPLE_PIM_BIN_DIR
 * 3. PATH lookup (which calendar-cli)
 * 4. ~/.local/bin/ (setup.sh --install target)
 */
function resolveBinDir(config?: PluginConfig): string {
  // 1. Plugin config
  if (config?.binDir && existsSync(join(config.binDir, "calendar-cli"))) {
    return config.binDir;
  }

  // 2. Env var
  const envBinDir = process.env.APPLE_PIM_BIN_DIR;
  if (envBinDir && existsSync(join(envBinDir, "calendar-cli"))) {
    return envBinDir;
  }

  // 3. Common PATH locations
  const pathDirs = (process.env.PATH || "").split(":").filter(Boolean);
  for (const dir of pathDirs) {
    if (existsSync(join(dir, "calendar-cli"))) {
      return dir;
    }
  }

  // 4-5. Standard locations via findSwiftBinDir
  return findSwiftBinDir();
}

/**
 * Check if a workspace has an apple-pim config directory by convention.
 * Convention: {workspaceDir}/apple-pim/config.json
 */
function resolveWorkspaceConfigDir(workspaceDir?: string): string | undefined {
  if (!workspaceDir) return undefined;
  const conventionPath = join(workspaceDir, "apple-pim");
  return existsSync(join(conventionPath, "config.json")) ? conventionPath : undefined;
}

/**
 * Resolve per-call environment overrides for workspace isolation.
 *
 * Priority chain (per parameter):
 * 1. Tool parameter (per-call override)
 * 2. Workspace convention ({workspaceDir}/apple-pim/)
 * 3. Plugin config (gateway-level default)
 * 4. Process env (APPLE_PIM_CONFIG_DIR / APPLE_PIM_PROFILE)
 * 5. Default (~/.config/apple-pim/)
 */
function resolveEnvOverrides(
  args: ToolArgs,
  config?: PluginConfig,
  workspaceDir?: string
): Record<string, string> {
  const env: Record<string, string> = {};

  // Resolve configDir with workspace convention at priority 2
  const workspaceConfigDir = resolveWorkspaceConfigDir(workspaceDir);
  const configDir = args.configDir || workspaceConfigDir || config?.configDir || process.env.APPLE_PIM_CONFIG_DIR;
  if (configDir) {
    env.APPLE_PIM_CONFIG_DIR = configDir.replace(/^~/, homedir());
  }

  // Resolve profile
  const profile = args.profile || config?.profile || process.env.APPLE_PIM_PROFILE;
  if (profile) {
    env.APPLE_PIM_PROFILE = profile;
  }

  return env;
}

/** Build a tool result with the required content + details shape. */
function toolResult(text: string, details?: unknown) {
  return {
    content: [{ type: "text" as const, text }],
    details,
  };
}

/**
 * OpenClaw plugin entry point.
 *
 * Uses definePluginEntry from the SDK. Registers tool factories (not static
 * tools) so each agent gets per-workspace config resolution via ctx.workspaceDir.
 */
export default definePluginEntry({
  id: "apple-pim-cli",
  name: "Apple PIM",
  description: "macOS Calendar, Reminders, Contacts, and Mail via native Swift CLIs",

  register(api) {
    // package.json declares only ./src/index.ts as an extension, so the channel entry
    // has to be reached from here or defineChannelPluginEntry never runs and the
    // channel is silently absent at runtime.
    appleMailChannelEntry.register(api);

    // Govern agent-originated mail (`apple_pim_mail action:"send"`) against the same egress
    // policy the channel's reply path enforces. Without this, envelope-only containment covers
    // replies but not sends: an agent could originate mail to anyone, outside the allowlist and
    // loop guard (#98). Reply is already gated in the tool handler and cannot add recipients, so
    // only `send` needs a hook. Runs in the gateway, where `api.config` carries the channel
    // block the tool process never sees.
    api.on("before_tool_call", (event) => {
      if (event.toolName !== "apple_pim_mail") {
        return;
      }
      if ((event.params as { action?: unknown }).action !== "send") {
        return;
      }
      // Scope the policy to the sender identity the send claims (`from`), so a multi-account
      // install cannot let one account's allowlist authorize a send as another.
      const from = typeof event.params.from === "string" ? event.params.from : undefined;
      const policy = resolveSendEgressPolicy(api.config, from);
      // No apple-mail channel configured: the send tool stays ungoverned, as it was before the
      // channel existed. Containment is the channel's contribution, not the bare tool's.
      if (!policy) {
        return;
      }
      const decision = evaluateSend(event.params, policy);
      if (decision.kind === "allow") {
        return;
      }
      if (decision.kind === "loop") {
        return {
          block: true,
          blockReason:
            `Refusing to send: ${decision.addresses.join(", ")} is one of the agent's own ` +
            `addresses, so this send would loop mail back into the channel.`,
        };
      }
      const subject = typeof event.params.subject === "string" ? event.params.subject : "";
      return {
        requireApproval: {
          title: "Send email to unlisted recipient",
          description: describeSendApproval(decision.unlisted, subject),
          severity: "warning",
          // No allow-always: persisting an arbitrary recipient into the egress allowlist is a
          // config decision the operator should make deliberately, not a one-tap side effect.
          allowedDecisions: ["allow-once", "deny"],
          timeoutMs: 120_000,
        },
      };
    });

    const config = api.pluginConfig as PluginConfig | undefined;
    const binDir = resolveBinDir(config);

    // Mail attachments policy is read by the JS-side validator from
    // process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG. If the user configured
    // an override via the gateway config schema, surface it once at init —
    // the value is host-level (same for every call), so a single assignment
    // is correct and avoids per-call env races.
    if (config?.mailAttachmentsConfig && !process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG) {
      process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG = config.mailAttachmentsConfig.replace(/^~/, homedir());
    }

    for (const tool of tools) {
      const openclawName = TOOL_NAME_MAP[tool.name];
      const handler = HANDLERS[tool.name];

      if (!openclawName || !handler) continue;

      // Register as factory for per-workspace context resolution.
      // Pass the stable tool name explicitly so `openclaw plugins inspect`
      // can render names for factory-registered tools instead of `(anonymous)`.
      api.registerTool((ctx) => {
        const workspaceDir = ctx.workspaceDir;

        return {
          name: openclawName,
          label: openclawName,
          description: tool.description,
          parameters: tool.inputSchema as Record<string, unknown>,

          execute: async (
            _toolCallId: string,
            params: Record<string, unknown>,
          ) => {
            // Runtime validation — ensure required 'action' field is present and valid
            if (typeof params.action !== "string" || !params.action) {
              return toolResult(
                JSON.stringify({ success: false, error: "Missing required 'action' parameter" }, null, 2),
                { domain: tool.name, action: null },
              );
            }
            const toolArgs = params as ToolArgs;

            // Per-call environment isolation — never mutates process.env
            const envOverrides = resolveEnvOverrides(toolArgs, config, workspaceDir);
            const { runCLI } = createCLIRunner(binDir, envOverrides);

            try {
              const result = await handler(toolArgs, runCLI);

              // Apply datamarking for prompt injection defense
              const markedResult = markToolResult(result, tool.name);
              const preamble = getDatamarkingPreamble(tool.name);

              return toolResult(
                `${preamble}\n\n${JSON.stringify(markedResult, null, 2)}`,
                { domain: tool.name, action: toolArgs.action },
              );
            } catch (error: unknown) {
              const message = error instanceof Error ? error.message : String(error);
              return toolResult(
                JSON.stringify({ success: false, error: message }, null, 2),
                { domain: tool.name, action: toolArgs.action },
              );
            }
          },
        };
      }, { name: openclawName });
    }
  },
});
