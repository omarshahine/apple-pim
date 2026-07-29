/**
 * Durable key/value storage the plugin owns outright.
 *
 * The host's `openKeyedStore` is gated on `trustedOfficialInstall`, which is granted only to
 * packages in OpenClaw's official external plugin catalog. That is not a property of how a
 * plugin is installed, so no install path reaches it for a third-party plugin: a local
 * `plugins install --force` was tried and refused exactly like a path load. This channel
 * therefore cannot use it, and every durable surface it has is load-bearing:
 *
 * - the poll cursor, or every restart reprocesses the mailbox
 * - thread records, or the reply rule is inert
 * - the quarantine, or refused senders become readable again
 * - the run budget, or a crash loop spends without limit
 *
 * So it keeps its own SQLite database. One file, one table, the same narrow
 * `lookup`/`register` interface the four callers already used, so nothing above this
 * changed shape when the storage moved.
 *
 * Values are JSON. The rows here are small structured records, not documents, and a schema
 * per caller would buy nothing while making each new store a migration.
 */

import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";

/** What every caller in this channel needs, and nothing more. */
export type KeyedStore<T> = {
  lookup(key: string): Promise<T | undefined>;
  register(key: string, value: T): Promise<void>;
};

/**
 * Where the database lives.
 *
 * Follows `OPENCLAW_STATE_DIR` so a dev gateway keeps its state separate from the operator's
 * real one. Getting this wrong would have a test run write into the live channel's cursor.
 */
export function storeDirectory(): string {
  const stateDir = process.env.OPENCLAW_STATE_DIR?.trim();
  const root = stateDir && stateDir.length > 0 ? stateDir : path.join(os.homedir(), ".openclaw");
  return path.join(expandHome(root), "apple-pim");
}

function expandHome(input: string): string {
  return input.startsWith("~/") ? path.join(os.homedir(), input.slice(2)) : input;
}

/**
 * Resolved at runtime rather than imported.
 *
 * Bundlers targeting a Node version that predates `node:sqlite` do not recognize the
 * specifier and rewrite it to a bare `sqlite`, which then fails to resolve at load time with
 * `Cannot find module 'sqlite'` and takes the whole plugin down with it. A runtime require
 * is opaque to that rewriting.
 */
type SqliteDatabase = {
  exec(sql: string): void;
  prepare(sql: string): { get(...params: unknown[]): unknown; run(...params: unknown[]): unknown };
  close(): void;
};

function loadSqlite(): new (filename: string) => SqliteDatabase {
  const require = createRequire(import.meta.url);
  return (require("node:sqlite") as { DatabaseSync: new (f: string) => SqliteDatabase })
    .DatabaseSync;
}

let db: SqliteDatabase | undefined;

/**
 * Opens the shared database, creating it on first use.
 *
 * One connection for the whole plugin: SQLite serializes writers anyway, and separate
 * handles to one file would trade a lock we control for one we do not.
 */
function database(): SqliteDatabase {
  if (db) {
    return db;
  }
  const dir = storeDirectory();
  mkdirSync(dir, { recursive: true });
  const DatabaseSync = loadSqlite();
  const opened = new DatabaseSync(path.join(dir, "mail-channel.sqlite"));
  // WAL so a poll cycle writing a cursor never blocks on a reader, and normal synchronous
  // because losing the last cursor write to a power cut costs one reprocessed page.
  opened.exec("PRAGMA journal_mode = WAL");
  opened.exec("PRAGMA synchronous = NORMAL");
  opened.exec(`
    CREATE TABLE IF NOT EXISTS keyed_store (
      namespace TEXT NOT NULL,
      key       TEXT NOT NULL,
      value     TEXT NOT NULL,
      PRIMARY KEY (namespace, key)
    )
  `);
  db = opened;
  return opened;
}

/**
 * A namespaced store.
 *
 * Namespaces keep the four callers from colliding on a shared key, which matters because
 * they all key by account id.
 */
export function openStore<T>(namespace: string): KeyedStore<T> {
  return {
    lookup: async (key: string) => {
      const row = database()
        .prepare("SELECT value FROM keyed_store WHERE namespace = ? AND key = ?")
        .get(namespace, key) as { value?: string } | undefined;
      if (row?.value === undefined) {
        return undefined;
      }
      try {
        return JSON.parse(row.value) as T;
      } catch (error) {
        // Corrupt is not absent, and collapsing the two here would fail open on the surfaces
        // that matter most: an unreadable quarantine row would read as "nothing is
        // quarantined" and re-expose every sender the channel had refused, and an unreadable
        // budget row would read as "no runs yet" and hand back a full spend allowance. Throw
        // instead. The caller holds the channel idle with a message naming this row, which
        // is recoverable by deleting it and losing only what that row held.
        throw new Error(
          `Corrupt value in ${namespace}/${key}: ${String(error)}. Delete this row to rebuild it.`,
        );
      }
    },
    register: async (key: string, value: T) => {
      database()
        .prepare(
          `INSERT INTO keyed_store (namespace, key, value) VALUES (?, ?, ?)
           ON CONFLICT(namespace, key) DO UPDATE SET value = excluded.value`,
        )
        .run(namespace, key, JSON.stringify(value));
    },
  };
}

/** Closes the connection. For tests and shutdown; reopens on next use. */
export function closeStore(): void {
  db?.close();
  db = undefined;
}
