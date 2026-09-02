// Covers the wiring between the two CLI calls a reply now makes, which the pure helpers in
// runtime.test.ts cannot reach: that the sender reads the message it is answering and hands
// `smtp-send` a body with the original quoted beneath the answer.
//
// A stub `mail-cli` on the sender's `binDir` stands in for the real one. Faking it at the
// process boundary is what makes the argv assertions meaningful: they are the exact
// arguments the Swift CLI would have received.
import { describe, it, before, after } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtemp, rm, writeFile, readFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { createMailCliSender } from "./runtime.ts";

const ORIGINAL = {
  sender: "Omar Shahine <omar@shahine.com>",
  dateSent: "2026-09-02T01:04:00.000Z",
  content: "Are you looking at the family calendar or my personal calendar",
};

let binDir: string;
let argvLog: string;

/** Writes a stub `mail-cli` that logs its argv and answers `get` however this test needs. */
async function installStub(getResponse: string, getExitCode = 0): Promise<void> {
  const script = `#!/bin/sh
printf '%s\\0' "$@" >> "${argvLog}"
case "$1" in
  get)
    ${getExitCode === 0 ? `cat <<'JSON'\n${getResponse}\nJSON` : `echo 'mail-cli: no such message' >&2; exit ${getExitCode}`}
    ;;
  smtp-send)
    echo '{"success":true,"messageId":"sent-123@icloud.com"}'
    ;;
esac
`;
  const file = path.join(binDir, "mail-cli");
  await writeFile(file, script);
  await chmod(file, 0o755);
  await writeFile(argvLog, "");
}

/** Argv as the stub received it. NUL-delimited: a reply body spans several lines. */
async function recordedArgv(): Promise<string[]> {
  const raw = await readFile(argvLog, "utf8");
  return raw.split("\0").slice(0, -1);
}

/** The argv element following `--body`, i.e. the outgoing message text. */
async function sentBody(): Promise<string> {
  const argv = await recordedArgv();
  const index = argv.lastIndexOf("--body");
  assert.notEqual(index, -1, "smtp-send was never given a body");
  return argv[index + 1] ?? "";
}

describe("createMailCliSender", () => {
  before(async () => {
    binDir = await mkdtemp(path.join(tmpdir(), "mail-cli-stub-"));
    argvLog = path.join(binDir, "argv.log");
  });
  after(async () => {
    await rm(binDir, { recursive: true, force: true });
  });

  it("quotes the message it is answering beneath the agent's reply", async () => {
    await installStub(JSON.stringify({ success: true, message: ORIGINAL }));
    const send = createMailCliSender({ binDir, fromAddress: "agent@icloud.com", accountId: "UUID" });

    const result = await send({
      messageId: "A9EC@shahine.com",
      to: "omar@shahine.com",
      body: "Neither.",
      subject: "Social Circuit",
    });

    assert.deepEqual(result, { sentMessageId: "sent-123@icloud.com" });
    const body = await sentBody();
    // The attribution renders in the host's timezone, so the calendar date is whatever the
    // machine running this says it is. Pinning it here would pass in Seattle and fail in CI.
    assert.match(
      body,
      /^Neither\.\n\nOn Sep [12], 2026, at \d{1,2}:\d{2} [AP]M, Omar Shahine <omar@shahine\.com> wrote:\n\n/,
    );
    assert.ok(
      body.endsWith("> Are you looking at the family calendar or my personal calendar"),
      `quoted original missing from body: ${JSON.stringify(body)}`,
    );
  });

  it("scopes the quote read to the configured account", async () => {
    // SQLite matches a mailbox name in every account, so an unscoped read can quote a
    // different account's message back at the sender.
    await installStub(JSON.stringify({ success: true, message: ORIGINAL }));
    const send = createMailCliSender({ binDir, accountId: "UUID" });
    await send({ messageId: "A9EC@shahine.com", to: "omar@shahine.com", body: "Neither." });

    const argv = await recordedArgv();
    assert.deepEqual(argv.slice(0, 9), [
      "get",
      "--id",
      "A9EC@shahine.com",
      "--account",
      "UUID",
      "--engine",
      "sqlite",
      "--format",
      "json",
    ]);
  });

  it("still sends the reply when the original cannot be read", async () => {
    // The answer is the message; the quote is a courtesy. Losing the courtesy must not cost
    // the operator the answer.
    await installStub("", 1);
    const warnings: string[] = [];
    const send = createMailCliSender({ binDir, accountId: "UUID", warn: (m) => warnings.push(m) });

    const result = await send({
      messageId: "gone@shahine.com",
      to: "omar@shahine.com",
      body: "Neither.",
    });

    assert.deepEqual(result, { sentMessageId: "sent-123@icloud.com" });
    assert.equal(await sentBody(), "Neither.");
    // Degraded and silent is indistinguishable from never attempted.
    assert.equal(warnings.length, 1);
    assert.match(warnings[0] ?? "", /without the original below it/);
  });
});
