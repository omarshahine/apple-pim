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
import { runPollLoop, type CursorStore } from "./poll.ts";
import {
  createMailCliDeps,
  createMailCliSender,
  readTrustedSenders,
} from "./runtime.ts";
import { checkChannelConfig } from "./config-check.ts";
import { RunBudget, resolveRateLimits, type BreakerStore } from "./rate-limit.ts";
import { ThreadRecords, type ThreadRecordStore } from "./thread-store.ts";
import { openStore, storeDirectory } from "./store.ts";
import {
  loadQuarantine,
  quarantineMessage,
  quarantineSnapshot,
} from "../../lib/mail-quarantine.js";
import { dispatchAdmittedMessage } from "./dispatch.ts";
import { dispatchReplyWithBufferedBlockDispatcher } from "openclaw/plugin-sdk/reply-dispatch-runtime";

/** Account shape this channel resolves from config. */
export type ResolvedAppleMailAccount = {
  accountId?: string | null;
  config: {
    /** Mail.app account name, as reported by JXA. Selects the trusted authserv-id set. */
    account?: string;
    /**
     * SQLite account UUID, from `mail-cli accounts --engine sqlite`. Scopes reads to one
     * account; without it a mailbox name matches in every account.
     */
    accountId?: string;
    dmPolicy?: string;
    allowFrom?: Array<string | number>;
    /**
     * Minimum identifier authentication strength required to authorize a sender.
     *
     * Deliberately narrower than `IdentifierAuthentication`, which also has `unverified`.
     * Offering it here would add a setting with no distinct effect: this channel never scores
     * an address or a domain `mutable`, so a minimum of `unverified` and a minimum of
     * `mutable` admit exactly the same mail. `mutable` stays as the single break-glass value
     * because it is the one already shipped. A test pins the equivalence, so if a future
     * mapping does emit `mutable` for an address, the omission stops being harmless and the
     * test fails.
     */
    minIdentifierAuthentication?: "verified" | "asserted" | "mutable";
    /** Addresses the agent sends as. Used for the inbound and outbound loop guards. */
    selfAddresses?: string[];
    /** Recipients the agent may originate mail to. Egress is default-deny without this. */
    egressAllowlist?: string[];
    /** The operator's own addresses. Always permitted reply recipients. */
    operatorAddresses?: string[];
    /** Seconds between Envelope Index polls. */
    pollIntervalSeconds?: number;
    /** Mailbox to poll. Not always INBOX: mail is often archived on arrival. */
    mailbox?: string;
    /** Messages per listing page before widening to reach the cursor. */
    pageSize?: number;
    /** Path to trusted-senders.json. */
    trustedSendersPath?: string;
    /**
     * Circuit breaker on agent runs. Default-deny bounds who may drive the agent, not how
     * much: one permitted correspondent in a loop is otherwise unlimited model calls.
     */
    maxAgentRunsPerHour?: number;
    maxAgentRunsPerDay?: number;
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
 * Runs one account's poll loop for the lifetime of the channel.
 *
 * `startAccount` awaits the loop rather than returning once it is running. Returning early
 * looks like a channel that started and then exited, and the gateway restarts it on that
 * basis every few seconds. The promise is also kept so `stopAccount` can wait for the
 * current cycle to settle instead of tearing down mid-classification.
 */
const loops = new Map<string, Promise<void>>();

const gateway: NonNullable<ChannelPlugin<ResolvedAppleMailAccount>["gateway"]> = {
  startAccount: async (ctx) => {
    const config = ctx.account.config;

    const deps = createMailCliDeps({
      account: config.account,
      accountId: config.accountId,
      trustedSendersPath: config.trustedSendersPath,
    });

    let store: CursorStore;
    let threads: ThreadRecords;
    let quarantineStore: ReturnType<typeof openStore<[string, string][]>>;
    let quarantineKey: string;
    let budget: RunBudget;
    let limits: ReturnType<typeof resolveRateLimits>;
    try {
      // Storage the plugin owns. The host's `openKeyedStore` is gated on
      // `trustedOfficialInstall`, which only packages in OpenClaw's official external catalog
      // receive; no install path reaches it for a third-party plugin, so this channel keeps
      // its own SQLite database rather than depending on a grant it cannot obtain.
      //
      // Opening it can fail for reasons retrying cannot fix: an unwritable state directory, a
      // Node without `node:sqlite`, a corrupt row. `startAccount` is awaited now, so letting
      // one of those reject would mark the channel crashed and burn all ten restart attempts
      // reprinting the same error. Fail once and hold instead.
      store = openStore<PollCursor>(`${CHANNEL_ID}:cursor`) as CursorStore;

      // Threads the agent has replied in. Hydrated once; admission reads it per message, so it
      // is held in memory rather than round-tripped to the store inside the poll loop.
      threads = new ThreadRecords(
        openStore(`${CHANNEL_ID}:threads`) as ThreadRecordStore,
        `${CHANNEL_ID}:${ctx.accountId}`,
      );
      await threads.hydrate();

      // Messages the channel refuses are quarantined for the mail tool too. Without this the
      // envelope-only prompt would be a bypass: a dropped message still has an id, and
      // `apple_pim_mail` would happily read the body the channel just declined to deliver.
      // Durable, because the cursor moves past a dropped message and it is never reclassified,
      // so an in-memory set would forget it at the next restart.
      quarantineStore = openStore<[string, string][]>(`${CHANNEL_ID}:quarantine`);
      quarantineKey = `${CHANNEL_ID}:${ctx.accountId}`;
      loadQuarantine(quarantineKey, await quarantineStore.lookup(quarantineKey));

      limits = resolveRateLimits(config);
      budget = new RunBudget(
        openStore(`${CHANNEL_ID}:budget`) as BreakerStore,
        `${CHANNEL_ID}:${ctx.accountId}`,
        limits,
      );
      await budget.hydrate();
    } catch (error) {
      ctx.log?.error?.(
        `apple-mail: durable storage unavailable (${String(error)}). The channel needs it for ` +
          `its poll cursor, thread records, quarantine, and run budget, and will not run ` +
          `without them: a lost cursor reprocesses the mailbox and a lost quarantine ` +
          `un-blocks refused senders. Check that ${storeDirectory()} is writable and that ` +
          `this Node build has node:sqlite (22.13+).`,
      );
      // Held rather than returned. A returning `startAccount` reads as an exited channel and
      // is restarted every few seconds; none of the causes above are fixed by retrying.
      await new Promise<void>((resolve) => {
        if (ctx.abortSignal.aborted) {
          resolve();
          return;
        }
        ctx.abortSignal.addEventListener("abort", () => resolve(), { once: true });
      });
      return;
    }

    const minIdentifierAuthentication = config.minIdentifierAuthentication ?? "asserted";
    const allowFrom = (config.allowFrom ?? []).map((entry) => String(entry));

    // Admission needs `openclaw.json` and `trusted-senders.json` to agree, and every way
    // they can disagree fails closed and therefore silently. Say so at startup, once, rather
    // than leaving the operator to infer it from an agent that reads mail and never answers.
    const findings = checkChannelConfig({
      allowFrom,
      selfAddresses: config.selfAddresses ?? [],
      minIdentifierAuthentication,
      trustedSendersPath: config.trustedSendersPath,
      ...(await readTrustedSenders(config.trustedSendersPath)),
    });
    for (const finding of findings) {
      ctx.log?.warn?.(`apple-mail [${finding.code}]: ${finding.message}`);
    }


    const loop = runPollLoop(
      {
        ...deps,
        onDropped: async (messages) => {
          for (const entry of messages) {
            quarantineMessage(quarantineKey, entry.message.messageId, entry.decision.reason);
          }
          await quarantineStore.register(quarantineKey, quarantineSnapshot(quarantineKey));
        },
        onAdmitted: async (messages) => {
          let completed = 0;
          for (const message of messages) {
            // Checked per message, not once per batch. A single check would let a batch of
            // 25 run against a budget with 1 left, which is not a cap. Ahead of the
            // embedder override too, so taking over delivery cannot take over the cap.
            if (!budget.check().allowed) {
              return { completed };
            }
            // Spend before the run, not after: a run that throws still consumed a model
            // call, and a breaker that only counts successes cannot bound a crash loop.
            const spend = await budget.consume();
            if (!spend.persisted) {
              ctx.log?.warn?.(
                `apple-mail: agent-run budget not persisted (${String(spend.error)}); the cap ` +
                  `still holds for this process but will not survive a restart`,
              );
            }
            // Tests and embedders can take over delivery, one message at a time so the
            // budget and the partial cursor still apply to them.
            if (admittedHandler) {
              await admittedHandler([message]);
              completed += 1;
              continue;
            }
            await dispatchAdmittedMessage(
              message,
              {
                dispatchReply: dispatchReplyWithBufferedBlockDispatcher,
                sendReply: createMailCliSender({ account: config.account }),
                onSuppressed: ({ address, reason }) =>
                  ctx.log?.info?.(`apple-mail: reply to ${address} suppressed (${reason})`),
                // The reply has already been sent by this point, so a store failure must not
                // surface as a failed dispatch. It fails closed instead: the thread goes
                // unrecorded and a later answer is denied, which is worth a warning.
                recordThread: async (reply) => {
                  try {
                    await threads.record(reply);
                  } catch (error) {
                    ctx.log?.warn?.(
                      `apple-mail: reply sent but thread not recorded (${String(error)}); a later reply in this thread will not be permitted`,
                    );
                  }
                },
              },
              {
                cfg: ctx.cfg,
                operatorAddresses: config.operatorAddresses ?? [],
                egressAllowlist: config.egressAllowlist ?? [],
                selfAddresses: config.selfAddresses ?? [],
                sessionPrefix: `${CHANNEL_ID}:${ctx.accountId}`,
              },
            );
            completed += 1;
          }
          return { completed };
        },
        onError: (error) => ctx.log?.warn?.(`apple-mail poll failed: ${String(error)}`),
        checkBudget: () => budget.check(),
        // The mid-batch path reports only how many were left, because the budget closed
        // between messages and the window that bound it is the breaker's business, not the
        // loop's. Say what is known rather than interpolating an absent field.
        onThrottled: ({ window, retryAtMs, pending }) => {
          const bound = window
            ? `${window} limit of ${window === "day" ? limits.perDay : limits.perHour}`
            : `limit of ${limits.perHour}/hour, ${limits.perDay}/day`;
          ctx.log?.warn?.(
            `apple-mail: circuit breaker open (${bound} agent runs reached); ` +
              `holding ${pending} message(s)` +
              (retryAtMs ? ` until ${new Date(retryAtMs).toISOString()}` : ""),
          );
        },
        // Informational now, not a warning: the page is the oldest unprocessed mail, so a
        // full one means the backlog is still draining, not that anything was skipped.
        onTruncated: ({ mailbox, limit }) =>
          ctx.log?.info?.(
            `apple-mail: ${mailbox} returned a full page of ${limit}; more unprocessed mail ` +
              `remains and will be read next cycle`,
          ),
      },
      {
        mailbox: config.mailbox ?? DEFAULT_MAILBOX,
        limit: config.pageSize ?? DEFAULT_PAGE,
        cursorKey: `${CHANNEL_ID}:${ctx.accountId}`,
        intervalMs: (config.pollIntervalSeconds ?? DEFAULT_POLL_SECONDS) * 1000,
        classify: {
          minIdentifierAuthentication,
          allowFrom,
          selfAddresses: config.selfAddresses ?? [],
          // A live view, not a snapshot: a reply sent this cycle has to be visible to the
          // next one, or the correspondent's answer arrives before the thread is recorded.
          get threadRecords() {
            return threads.all();
          },
        },
      },
      store,
      ctx.abortSignal,
    );

    loops.set(ctx.accountId, loop);
    // Awaited, not fired and forgotten. The gateway treats a `startAccount` that returns as
    // an exited channel and restarts it every few seconds; the loop already runs until the
    // abort signal, so awaiting it is what "the channel is up" means here.
    await loop;
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
  id: CHANNEL_ID,
  name: "Apple Mail",
  description:
    "Apple Mail channel for OpenClaw. Polls the local Mail.app store and authorizes senders by DKIM/SPF authentication strength.",
  plugin: appleMailChannelPlugin,
});
