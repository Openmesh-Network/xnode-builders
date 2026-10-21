import assert from "node:assert";
import { test } from "node:test";

import { greet } from "../index.js";

test("greet", () => {
  assert.strictEqual(greet(), "hello");
});
