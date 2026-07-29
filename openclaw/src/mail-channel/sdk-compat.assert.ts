/**
 * Compile-time guard, not a test.
 *
 * `dispatch.ts` narrows the reply pipeline to the few fields it uses rather than importing
 * the full SDK type, which keeps the module testable with a small fake. The risk is that a
 * hand-written narrowing drifts from the real export and only fails at the seam.
 *
 * This asserts the real `dispatchReplyWithBufferedBlockDispatcher` is assignable to that
 * narrowing. It already caught one mismatch: `deliver` must return `Promise<unknown>`, and
 * the local type had allowed a synchronous return.
 */
import { dispatchReplyWithBufferedBlockDispatcher } from "openclaw/plugin-sdk/reply-dispatch-runtime";
import type { ReplyDispatcher } from "./dispatch.ts";

const _sdkSatisfiesLocalNarrowing: ReplyDispatcher = dispatchReplyWithBufferedBlockDispatcher;
void _sdkSatisfiesLocalNarrowing;
