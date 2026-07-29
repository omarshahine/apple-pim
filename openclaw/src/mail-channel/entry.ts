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
import type { ClassifiedMessage, PollCursor } from "./inbound.ts";
import type { PluginRuntime } from "openclaw/plugin-sdk/runtime-store";
import { runPollLoop, type CursorStore } from "./poll.ts";
import { createMailCliDeps } from "./runtime.ts";

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
    /** Mailbox to poll. Not always INBOX: mail is often archived on arrival. */
    mailbox?: string;
    /** Messages per listing page before widening to reach the cursor. */
    pageSize?: number;
    /** Path to trusted-senders.json. */
    trustedSendersPath?: string;
  };
};

const CHANNEL_ID = "apple-mail";
const DEFAULT_POLL_SECONDS = 60;
const DEFAULT_MAILBOX = "INBOX";
const DEFAULT_PAGE = 25;

/**
 * Where admitted mail goes.
 *
 * Left injectable rather than reaching into `ctx.channelRuntime`: that surface is typed
 * `{ runtimeContexts, [key: string]: unknown }`, so calling its reply dispatcher means
 * casting through `unknown`. Wiring agent dispatch is the next step and is deliberately
 * not guessed at here.
 */
export type AdmittedHandler = (messages: ClassifiedMessage[]) => Promise<void> | void;

let admittedHandler: AdmittedHandler | undefined;

/**
 * Captured at registration.
 *
 * The keyed store lives on `PluginRuntime`, not on the `RuntimeEnv` handed to
 * `startAccount`, so it has to be taken here via the entry's `setRuntime` hook.
 */
let pluginRuntime: PluginRuntime | undefined;

/** Overrides the default handler. Used by the gateway wiring and by tests. */
export function setAdmittedHandler(handler: AdmittedHandler | undefined): void {
  admittedHandler = handler;
}

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

/**
 * Starts one account's poll loop and stops it on shutdown.
 *
 * `startAccount` returns once the loop is running rather than awaiting it, because the
 * loop only ends on abort and the gateway needs startup to complete. The promise is kept
 * so `stopAccount` can wait for the current cycle to settle instead of tearing down
 * mid-classification.
 */
const loops = new Map<string, Promise<void>>();

const gateway: NonNullable<ChannelPlugin<ResolvedAppleMailAccount>["gateway"]> = {
  startAccount: async (ctx) => {
    const config = ctx.account.config;
    const state = pluginRuntime?.state;
    if (!state) {
      // Without durable cursor storage the loop would re-read the mailbox from scratch on
      // every restart. Refuse to start rather than run in a state that looks fine and
      // silently reprocesses.
      ctx.log?.warn?.("apple-mail: plugin runtime unavailable; not starting the poll loop");
      return;
    }
    const store = state.openKeyedStore<PollCursor>({
      namespace: `${CHANNEL_ID}:cursor`,
      maxEntries: 64,
    }) as CursorStore;

    const deps = createMailCliDeps({
      account: config.account,
      trustedSendersPath: config.trustedSendersPath,
    });


    const loop = runPollLoop(
      {
        ...deps,
        onAdmitted: async (messages) => {
          if (!admittedHandler) {
            // Never silently swallow admitted mail: if nothing is wired to receive it,
            // say so once per batch rather than letting it vanish.
            ctx.log?.warn?.(
              `apple-mail: ${messages.length} message(s) admitted with no handler configured`,
            );
            return;
          }
          await admittedHandler(messages);
        },
        onError: (error) => ctx.log?.warn?.(`apple-mail poll failed: ${String(error)}`),
        onTruncated: ({ mailbox, limit }) =>
          ctx.log?.warn?.(
            `apple-mail: ${mailbox} had more than ${limit} unread messages; some were not read this cycle`,
          ),
      },
      {
        mailbox: config.mailbox ?? DEFAULT_MAILBOX,
        limit: config.pageSize ?? DEFAULT_PAGE,
        cursorKey: `${CHANNEL_ID}:${ctx.accountId}`,
        intervalMs: (config.pollIntervalSeconds ?? DEFAULT_POLL_SECONDS) * 1000,
        classify: {
          minIdentifierAuthentication: config.minIdentifierAuthentication ?? "asserted",
          allowFrom: (config.allowFrom ?? []).map((entry) => String(entry)),
          selfAddresses: config.selfAddresses ?? [],
        },
      },
      store,
      ctx.abortSignal,
    );

    loops.set(ctx.accountId, loop);
  },

  stopAccount: async (ctx) => {
    // The abort signal ends the loop; this just waits for the in-flight cycle.
    await loops.get(ctx.accountId)?.catch(() => {});
    loops.delete(ctx.accountId);
  },
};

export const appleMailChannelPlugin = createChatChannelPlugin<ResolvedAppleMailAccount>({
  base: { ...base, gateway },
  security,
});

export const appleMailChannelEntry = defineChannelPluginEntry({
  setRuntime: (runtime) => {
    pluginRuntime = runtime;
  },
  id: CHANNEL_ID,
  name: "Apple Mail",
  description:
    "Apple Mail channel for OpenClaw. Polls the local Mail.app store and authorizes senders by DKIM/SPF authentication strength.",
  plugin: appleMailChannelPlugin,
});
