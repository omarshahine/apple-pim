/**
 * Apple Mail channel entry.
 *
 * Registers the channel through the generic (non-bundled) path,
 * `defineChannelPluginEntry` from `openclaw/plugin-sdk/channel-core`, which is what an
 * external ClawHub plugin uses. The bundled helper `defineBundledChannelEntry` is for
 * in-tree channels and does not apply here.
 *
 * The security adapter is declared with a `dm` block on purpose. Core normalizes that into
 * `resolveDmPolicy`, which is what makes the channel visible to `openclaw security audit`.
 * That hook is optional, and channels that omit it silently skip the DM-policy audit
 * entirely, so declaring it is the difference between being audited and appearing safe.
 */

import {
  createChatChannelPlugin,
  defineChannelPluginEntry,
} from "openclaw/plugin-sdk/channel-core";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import type { ChannelPlugin } from "openclaw/plugin-sdk/channel-core";

/** Account shape this channel resolves from config. */
export type ResolvedAppleMailAccount = {
  accountId?: string | null;
  config: {
    /** Mail.app account name, as reported by JXA. Selects the trusted authserv-id set. */
    account?: string;
    dmPolicy?: string;
    allowFrom?: Array<string | number>;
    /** Minimum identifier authentication strength required to authorize a sender. */
    minIdentifierAuthentication?: "verified" | "asserted" | "mutable";
    /** Addresses the agent sends as. Used for the inbound and outbound loop guards. */
    selfAddresses?: string[];
    /** Recipients the agent may originate mail to. Egress is default-deny without this. */
    egressAllowlist?: string[];
    /** Seconds between Envelope Index polls. */
    pollIntervalSeconds?: number;
  };
};

const CHANNEL_ID = "apple-mail";

/** Reads one account's config block out of `channels.apple-mail`. */
function resolveAccount(cfg: OpenClawConfig, accountId?: string | null): ResolvedAppleMailAccount {
  const channels = (cfg as { channels?: Record<string, unknown> }).channels ?? {};
  const channel = (channels[CHANNEL_ID] ?? {}) as {
    accounts?: Record<string, ResolvedAppleMailAccount["config"]>;
  } & ResolvedAppleMailAccount["config"];
  const id = accountId ?? "default";
  // Account blocks inherit the channel-level block, so a single-account install can
  // configure everything at the top level without naming an account.
  const account = channel.accounts?.[id];
  return { accountId: id, config: { ...channel, ...(account ?? {}) } };
}

const base = {
  id: CHANNEL_ID,
  meta: {
    id: CHANNEL_ID,
    label: "Apple Mail",
    selectionLabel: "Apple Mail",
    docsPath: "docs/mail-channel-scenarios.md",
    blurb:
      "Reads the local Mail.app store and authorizes senders by transport authentication strength.",
  },
  capabilities: {
    // Mail is one-to-one plus threads. No group semantics, no reactions, no edit/unsend:
    // the transport has none of them, and claiming them would make core offer actions
    // this channel cannot honor.
    chatTypes: ["direct", "thread"],
    reply: true,
    threads: true,
    media: true,
  },
  config: {
    listAccountIds: (cfg: OpenClawConfig) => {
      const channels = (cfg as { channels?: Record<string, unknown> }).channels ?? {};
      const channel = (channels[CHANNEL_ID] ?? {}) as { accounts?: Record<string, unknown> };
      const ids = Object.keys(channel.accounts ?? {});
      return ids.length > 0 ? ids : ["default"];
    },
    resolveAccount,
  },
} satisfies Omit<
  ChannelPlugin<ResolvedAppleMailAccount>,
  "security" | "pairing" | "threading" | "outbound"
>;

/**
 * `dm` gives core everything it needs to synthesize `resolveDmPolicy`, so this channel
 * participates in the DM-policy security audit rather than skipping it.
 */
const security = {
  dm: {
    channelKey: CHANNEL_ID,
    resolvePolicy: (account: ResolvedAppleMailAccount) => account.config.dmPolicy,
    resolveAllowFrom: (account: ResolvedAppleMailAccount) => account.config.allowFrom,
    // Mail addresses are case-insensitive in practice; normalize before matching so an
    // allowlist entry and an inbound sender cannot differ only by case.
    normalizeEntry: (raw: string) => raw.trim().toLowerCase(),
    defaultPolicy: "allowlist",
  },
};

export const appleMailChannelPlugin = createChatChannelPlugin<ResolvedAppleMailAccount>({
  base,
  security,
});

export const appleMailChannelEntry = defineChannelPluginEntry({
  id: CHANNEL_ID,
  name: "Apple Mail",
  description:
    "Apple Mail channel for OpenClaw. Polls the local Mail.app store and authorizes senders by DKIM/SPF authentication strength.",
  plugin: appleMailChannelPlugin,
});
