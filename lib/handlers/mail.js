import { formatMailGetResult } from "../mail-format.js";
import { validateAttachments, validateDestDir } from "../safe-attachments.js";
import {
  assertMailReadable,
  assertMailRepliable,
  filterQuarantinedResults,
} from "../mail-quarantine.js";

export async function handleMail(args, runCLI) {
  const cliArgs = [];

  switch (args.action) {
    case "accounts":
      return await runCLI("mail-cli", ["accounts"]);

    case "mailboxes":
      cliArgs.push("mailboxes");
      if (args.account) cliArgs.push("--account", args.account);
      return await runCLI("mail-cli", cliArgs);

    case "messages":
      cliArgs.push("messages");
      if (args.mailbox) cliArgs.push("--mailbox", args.mailbox);
      if (args.account) cliArgs.push("--account", args.account);
      if (args.limit) cliArgs.push("--limit", String(args.limit));
      if (args.filter) cliArgs.push("--filter", args.filter);
      // A listing that includes a refused message hands the agent the envelope the channel
      // declined to deliver, so `drop` would only mean "delivered by a different route".
      // The withheld count is safe to report here: it does not depend on a query.
      return filterQuarantinedResults(await runCLI("mail-cli", cliArgs), { reportWithheld: true });

    case "get": {
      if (!args.id) throw new Error("Message ID is required for mail get");
      // The channel hands the agent envelopes and lets it fetch bodies it wants. That only
      // stays safe if a body the channel refused to deliver cannot be fetched here instead.
      assertMailReadable(args.id, "read");
      const getArgs = ["get", "--id", args.id];
      if (args.mailbox) getArgs.push("--mailbox", args.mailbox);
      if (args.account) getArgs.push("--account", args.account);
      if (args.format === "markdown") getArgs.push("--include-source");
      const result = await runCLI("mail-cli", getArgs);
      return await formatMailGetResult(result, args.format || "plain");
    }

    case "search":
      if (!args.query) throw new Error("Search query is required for mail search");
      cliArgs.push("search", args.query);
      if (args.field) cliArgs.push("--field", args.field);
      if (args.mailbox) cliArgs.push("--mailbox", args.mailbox);
      if (args.account) cliArgs.push("--account", args.account);
      if (args.limit) cliArgs.push("--limit", String(args.limit));
      if (args.since) cliArgs.push("--since", args.since);
      // Filtering search matters more than filtering listings: `--field content` reads every
      // candidate body, so an unfiltered hit is a content oracle. The agent probes for a
      // phrase and learns whether a quarantined message contains it, without ever calling
      // `get`. Withholding the row closes that without needing to inspect the query, and the
      // withheld count is deliberately not reported: a query-dependent count is the same
      // oracle wearing a different hat.
      return filterQuarantinedResults(await runCLI("mail-cli", cliArgs));

    case "update": {
      if (!args.id) throw new Error("Message ID is required for mail update");
      const updateArgs = ["update", "--id", args.id];
      if (args.read !== undefined) updateArgs.push("--read", String(args.read));
      if (args.flagged !== undefined) updateArgs.push("--flagged", String(args.flagged));
      if (args.junk !== undefined) updateArgs.push("--junk", String(args.junk));
      if (args.mailbox) updateArgs.push("--mailbox", args.mailbox);
      if (args.account) updateArgs.push("--account", args.account);
      return await runCLI("mail-cli", updateArgs);
    }

    case "move": {
      if (!args.id) throw new Error("Message ID is required for mail move");
      if (!args.toMailbox) throw new Error("Target mailbox (toMailbox) is required for mail move");
      const moveArgs = ["move", "--id", args.id, "--to-mailbox", args.toMailbox];
      if (args.toAccount) moveArgs.push("--to-account", args.toAccount);
      if (args.mailbox) moveArgs.push("--mailbox", args.mailbox);
      if (args.account) moveArgs.push("--account", args.account);
      return await runCLI("mail-cli", moveArgs);
    }

    case "delete": {
      if (!args.id) throw new Error("Message ID is required for mail delete");
      const delArgs = ["delete", "--id", args.id];
      if (args.mailbox) delArgs.push("--mailbox", args.mailbox);
      if (args.account) delArgs.push("--account", args.account);
      return await runCLI("mail-cli", delArgs);
    }

    case "batch_update": {
      if (!args.ids || !Array.isArray(args.ids) || args.ids.length === 0) {
        throw new Error("IDs array is required and cannot be empty");
      }
      const updates = args.ids.map((id) => {
        const obj = { id };
        if (args.read !== undefined) obj.read = args.read;
        if (args.flagged !== undefined) obj.flagged = args.flagged;
        if (args.junk !== undefined) obj.junk = args.junk;
        return obj;
      });
      const batchArgs = ["batch-update", "--json", JSON.stringify(updates)];
      if (args.mailbox) batchArgs.push("--mailbox", args.mailbox);
      if (args.account) batchArgs.push("--account", args.account);
      return await runCLI("mail-cli", batchArgs);
    }

    case "batch_delete": {
      if (!args.ids || !Array.isArray(args.ids) || args.ids.length === 0) {
        throw new Error("IDs array is required and cannot be empty");
      }
      const batchArgs = ["batch-delete", "--json", JSON.stringify(args.ids)];
      if (args.mailbox) batchArgs.push("--mailbox", args.mailbox);
      if (args.account) batchArgs.push("--account", args.account);
      return await runCLI("mail-cli", batchArgs);
    }

    case "send": {
      if (!args.to) throw new Error("At least one recipient (to) is required for send");
      if (!args.subject) throw new Error("Subject is required for send");
      if (!args.body) throw new Error("Body is required for send");
      const sendArgs = ["send"];
      const toList = Array.isArray(args.to) ? args.to : [args.to];
      for (const addr of toList) sendArgs.push("--to", addr);
      sendArgs.push("--subject", args.subject);
      sendArgs.push("--body", args.body);
      if (args.cc) {
        const ccList = Array.isArray(args.cc) ? args.cc : [args.cc];
        for (const addr of ccList) sendArgs.push("--cc", addr);
      }
      if (args.bcc) {
        const bccList = Array.isArray(args.bcc) ? args.bcc : [args.bcc];
        for (const addr of bccList) sendArgs.push("--bcc", addr);
      }
      if (args.from) sendArgs.push("--from", args.from);
      if (args.attachment) {
        const safe = validateAttachments(args.attachment);
        for (const p of safe) sendArgs.push("--attachment", p);
      }
      return await runCLI("mail-cli", sendArgs);
    }

    case "reply": {
      if (!args.id) throw new Error("Message ID is required for reply");
      if (!args.body) throw new Error("Body is required for reply");
      // Both gates, and they are not the same question. A refused message must not be read
      // at all; an `observe` message is readable and must not be answered. Without the
      // second, the channel suppressing its own reply to an unvetted sender accomplishes
      // nothing, because the agent can send one through this tool instead.
      assertMailReadable(args.id, "reply to");
      assertMailRepliable(args.id, "reply to");
      const replyArgs = ["reply", "--id", args.id, "--body", args.body];
      if (args.mailbox) replyArgs.push("--mailbox", args.mailbox);
      if (args.account) replyArgs.push("--account", args.account);
      if (args.attachment) {
        const safe = validateAttachments(args.attachment);
        for (const p of safe) replyArgs.push("--attachment", p);
      }
      return await runCLI("mail-cli", replyArgs);
    }

    case "save_attachment": {
      if (!args.id) throw new Error("Message ID is required for save_attachment");
      // Same gate as `get`, and more load-bearing: an attachment from a sender the channel
      // rejected is untrusted content being written to the operator's filesystem.
      assertMailReadable(args.id, "save an attachment from");
      const saveArgs = ["save-attachment", "--id", args.id];
      if (args.index !== undefined) saveArgs.push("--index", String(args.index));
      if (args.destDir) saveArgs.push("--dest-dir", validateDestDir(args.destDir));
      if (args.mailbox) saveArgs.push("--mailbox", args.mailbox);
      if (args.account) saveArgs.push("--account", args.account);
      return await runCLI("mail-cli", saveArgs);
    }

    case "auth_check": {
      if (!args.id) throw new Error("Message ID is required for auth_check");
      const authArgs = ["auth-check", "--id", args.id];
      if (args.trustedSenders) authArgs.push("--trusted-senders", args.trustedSenders);
      if (args.mailbox) authArgs.push("--mailbox", args.mailbox);
      if (args.account) authArgs.push("--account", args.account);
      return await runCLI("mail-cli", authArgs);
    }

    default:
      throw new Error(`Unknown mail action: ${args.action}`);
  }
}
