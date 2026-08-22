import { describe, expect, it } from "vitest";
import { handleMail } from "../../lib/handlers/mail.js";

// `mail-cli batch-update` / `batch-delete` emit a top-level `_lookup` summary
// unconditionally — the write-path locator's backend and its hit/mismatch/fallback counters.
// That is the right default AT THE CLI: the SQLite fast path degrades silently and correctly,
// so the counters are the only signal an operator has that it engaged at all.
//
// This boundary is where the agent reads instead, and the agent cannot act on any of it. The
// tests below pin that the summary is dropped for exactly the two batch actions that carry it,
// and that nothing else on the mail surface is filtered on the way through.

const batchResponse = () => ({
  success: true,
  message: "Batch update completed",
  updated: [{ id: "a@example.com", subject: "hi" }],
  updatedCount: 1,
  errors: [],
  errorCount: 0,
  _lookup: {
    backend: "sqlite",
    stats: { byIdHits: 1, byIdMismatches: 0, jxaFallbacks: 0, notFound: 0 },
  },
});

describe("write-path locator telemetry is not handed to the agent", () => {
  it("strips _lookup from batch_update", async () => {
    const result = await handleMail(
      { action: "batch_update", ids: ["a@example.com"], read: true },
      async () => batchResponse(),
    );
    expect(result).not.toHaveProperty("_lookup");
  });

  it("strips _lookup from batch_delete", async () => {
    const result = await handleMail(
      { action: "batch_delete", ids: ["a@example.com"] },
      async () => batchResponse(),
    );
    expect(result).not.toHaveProperty("_lookup");
  });

  it("keeps every other key of the batch response intact", async () => {
    const result = await handleMail(
      { action: "batch_update", ids: ["a@example.com"], read: true },
      async () => batchResponse(),
    );
    const { _lookup, ...expected } = batchResponse();
    expect(result).toEqual(expected);
  });

  it("passes a batch response through unchanged when the CLI emits no _lookup", async () => {
    const bare = { success: true, updated: [], updatedCount: 0, errors: [], errorCount: 0 };
    const result = await handleMail(
      { action: "batch_delete", ids: ["a@example.com"] },
      async () => bare,
    );
    expect(result).toEqual(bare);
  });

  it("does not filter non-batch actions", async () => {
    // Only the two batch commands emit the summary, so only they are filtered. A blanket
    // strip would quietly swallow an `_lookup` any future command chose to surface here.
    const result = await handleMail(
      { action: "accounts" },
      async () => ({ accounts: [], _lookup: "untouched" }),
    );
    expect(result._lookup).toBe("untouched");
  });
});
