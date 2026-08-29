import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { applyFieldSelection } from "../lib/fields.js";

describe("mail field selection", () => {
  it("preserves a single message wrapper", () => {
    const result = applyFieldSelection(
      {
        success: true,
        message: { id: "m1", sender: "omar@example.com", content: "hello", source: "raw" },
      },
      ["sender", "content"],
    );

    assert.deepEqual(result, {
      success: true,
      message: { id: "m1", sender: "omar@example.com", content: "hello" },
    });
  });
});
