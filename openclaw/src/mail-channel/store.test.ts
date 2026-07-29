/**
 * The plugin owns its storage because the host will not lend it any.
 *
 * `openKeyedStore` is gated on `trustedOfficialInstall`, granted only to packages in
 * OpenClaw's official external catalog. That is not about how a plugin is installed: a local
 * `plugins install --force` was refused exactly like a path load. A third-party plugin
 * cannot get there, so it brings its own database.
 */

import { describe, it, before, after } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { closeStore, openStore, storeDirectory } from "./store.ts";

/** Writes unparseable bytes into a row, which only a bug or a bad edit would produce. */
function corrupt(namespace: string, key: string): void {
  closeStore();
  const { DatabaseSync } = createRequire(import.meta.url)("node:sqlite") as {
    DatabaseSync: new (f: string) => { prepare(s: string): { run(...a: unknown[]): unknown }; close(): void };
  };
  const db = new DatabaseSync(path.join(tmp, "apple-pim", "mail-channel.sqlite"));
  db.prepare("UPDATE keyed_store SET value = ? WHERE namespace = ? AND key = ?").run(
    "{not json",
    namespace,
    key,
  );
  db.close();
}

let tmp: string;

before(() => {
  tmp = mkdtempSync(path.join(os.tmpdir(), "apple-pim-store-"));
  process.env.OPENCLAW_STATE_DIR = tmp;
});

after(() => {
  closeStore();
  rmSync(tmp, { recursive: true, force: true });
  delete process.env.OPENCLAW_STATE_DIR;
});

describe("openStore", () => {
  it("returns undefined for a key never written", async () => {
    assert.equal(await openStore("ns").lookup("absent"), undefined);
  });

  it("round-trips a structured value", async () => {
    const store = openStore<{ lastDateReceived: string; ids: string[] }>("cursor");
    await store.register("acct", { lastDateReceived: "2026-07-29T10:00:00Z", ids: ["a", "b"] });
    assert.deepEqual(await store.lookup("acct"), {
      lastDateReceived: "2026-07-29T10:00:00Z",
      ids: ["a", "b"],
    });
  });

  it("overwrites rather than accumulating", async () => {
    const store = openStore<number[]>("cursor");
    await store.register("k", [1]);
    await store.register("k", [2, 3]);
    assert.deepEqual(await store.lookup("k"), [2, 3]);
  });

  // All four callers key by account id, so without namespacing the cursor and the budget
  // would fight over the same row.
  it("keeps namespaces apart under an identical key", async () => {
    await openStore<string>("cursor").register("default", "cursor-value");
    await openStore<string>("budget").register("default", "budget-value");
    assert.equal(await openStore<string>("cursor").lookup("default"), "cursor-value");
    assert.equal(await openStore<string>("budget").lookup("default"), "budget-value");
  });

  it("keeps accounts apart within a namespace", async () => {
    const store = openStore<string>("threads");
    await store.register("work", "w");
    await store.register("personal", "p");
    assert.equal(await store.lookup("work"), "w");
    assert.equal(await store.lookup("personal"), "p");
  });

  // A budget or cursor that resets on restart is not one. This is the whole reason the
  // store exists rather than an in-memory map.
  it("survives closing and reopening the database", async () => {
    await openStore<{ runs: number[] }>("budget").register("acct", { runs: [1, 2, 3] });
    closeStore();
    assert.deepEqual(await openStore<{ runs: number[] }>("budget").lookup("acct"), {
      runs: [1, 2, 3],
    });
  });

  it("handles the empty and falsy values callers actually store", async () => {
    const store = openStore<unknown>("edge");
    for (const [key, value] of [
      ["empty-array", []],
      ["empty-object", {}],
      ["zero", 0],
      ["false", false],
      ["null", null],
    ] as const) {
      await store.register(key, value);
      assert.deepEqual(await store.lookup(key), value, key);
    }
  });

  it("puts its database under the configured state dir, not the operator's real one", () => {
    assert.equal(storeDirectory(), path.join(tmp, "apple-pim"));
  });
});

// Codex: treating a corrupt row as an absent one fails open on the two surfaces where that
// is worst. An unreadable quarantine reads as "nothing is quarantined" and re-exposes every
// refused sender; an unreadable budget reads as "no runs yet" and returns a full allowance.
describe("corrupt rows", () => {
  it("throws rather than reporting the key as absent", async () => {
    const store = openStore<string[]>("quarantine");
    await store.register("acct", ["still-fine"]);
    corrupt("quarantine", "acct");
    await assert.rejects(() => store.lookup("acct"), /Corrupt value in quarantine\/acct/);
  });

  it("names the row so it can be deleted", async () => {
    const store = openStore<number>("budget");
    await store.register("work", 1);
    corrupt("budget", "work");
    await assert.rejects(() => store.lookup("work"), /Delete this row to rebuild it/);
  });

  it("leaves neighbouring rows readable", async () => {
    const store = openStore<string>("cursor");
    await store.register("a", "good");
    await store.register("b", "also-good");
    corrupt("cursor", "a");
    await assert.rejects(() => store.lookup("a"));
    assert.equal(await store.lookup("b"), "also-good");
  });
});
