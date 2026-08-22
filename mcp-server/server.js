#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { dirname, join } from "path";
// Bundled: esbuild inlines this at build time, and `scripts/bump-version.sh`
// rewrites package.json then rebuilds dist, so the reported version cannot drift
// from the manifest the way a hardcoded literal did.
import pkg from "./package.json" with { type: "json" };
import { fileURLToPath } from "url";
import {
  markToolResult,
  getDatamarkingPreamble,
} from "../lib/sanitize.js";
import { createCLIRunner, findSwiftBinDir } from "../lib/cli-runner.js";
import { tools } from "../lib/schemas.js";
import { withAgentDX } from "../lib/agent-dx.js";
import { handleCalendar } from "../lib/handlers/calendar.js";
import { handleReminder } from "../lib/handlers/reminder.js";
import { handleContact } from "../lib/handlers/contact.js";
import { handleMail } from "../lib/handlers/mail.js";
import { handleApplePim } from "../lib/handlers/apple-pim.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

// MCP-specific binary search locations (relative to bundled server)
const mcpLocations = [
  join(__dirname, "..", "swift", ".build", "release"),
  join(__dirname, "..", "..", "swift", ".build", "release"),
];

const SWIFT_BIN_DIR = findSwiftBinDir(mcpLocations);
const { runCLI } = createCLIRunner(SWIFT_BIN_DIR);

// Wrap handlers with agent DX features (fields, dryRun, schema)
const handlers = {
  calendar: withAgentDX("calendar", handleCalendar),
  reminder: withAgentDX("reminder", handleReminder),
  contact: withAgentDX("contact", handleContact),
  mail: withAgentDX("mail", handleMail),
  "apple-pim": withAgentDX("apple-pim", handleApplePim),
};

// Main tool dispatcher
async function handleTool(name, args) {
  const handler = handlers[name];
  if (!handler) throw new Error(`Unknown tool: ${name}`);
  return await handler(args, runCLI);
}

// Create and run server
const server = new Server(
  {
    name: "apple-pim",
    version: pkg.version,
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    const result = await handleTool(name, args || {});

    // Apply datamarking to untrusted PIM content fields
    const markedResult = markToolResult(result, name);
    const preamble = getDatamarkingPreamble(name);

    return {
      content: [
        {
          type: "text",
          text: `${preamble}\n\n${JSON.stringify(markedResult, null, 2)}`,
        },
      ],
    };
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              success: false,
              error: error.message,
            },
            null,
            2
          ),
        },
      ],
      isError: true,
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
