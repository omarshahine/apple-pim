import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import { appleMailChannelPlugin } from "./entry.ts";

describe("Apple Mail channel configuration", () => {
  const cases = [
    { name: "PIM tools without any channels", cfg: {}, expected: { default: false } },
    { name: "PIM tools without Apple Mail", cfg: { channels: {} }, expected: { default: false } },
    { name: "an empty channel", channel: {}, expected: { default: false } },
    { name: "an empty sender list", channel: { selfAddresses: [] }, expected: { default: false } },
    { name: "an empty reply sender", channel: { selfAddresses: ["", "alias@example.com"] }, expected: { default: false } },
    { name: "a top-level sender", channel: { selfAddresses: ["agent@example.com"] }, expected: { default: true } },
    {
      name: "named accounts inheriting and overriding the sender",
      channel: {
        selfAddresses: ["agent@example.com"],
        accounts: {
          inherited: {},
          own: { selfAddresses: ["other@example.com"] },
          incomplete: { selfAddresses: [] },
        },
      },
      expected: { inherited: true, own: true, incomplete: false },
    },
    {
      name: "named accounts without a top-level sender",
      channel: { accounts: { complete: { selfAddresses: ["agent@example.com"] }, incomplete: {} } },
      expected: { complete: true, incomplete: false },
    },
  ];

  for (const scenario of cases) {
    it(`reports configuration for ${scenario.name}`, async () => {
      const cfg = (scenario.cfg ?? { channels: { "apple-mail": scenario.channel } }) as OpenClawConfig;
      const adapter = appleMailChannelPlugin.config;
      const states: Record<string, boolean> = {};
      for (const id of adapter.listAccountIds(cfg)) {
        const account = adapter.resolveAccount(cfg, id);
        states[id] = (await adapter.isConfigured?.(account, cfg)) ?? true;
        if (states[id] === false) {
          assert.match(adapter.unconfiguredReason?.(account, cfg) ?? "", /selfAddresses/);
        }
      }
      assert.deepEqual(states, scenario.expected);
    });
  }
});
