// Concept
// Check M7 answer payloads independently against the shared literal vectors.
//
// Technical depth
// Payload validation follows strict framing in the live clients. This runner
// tests only the decoded answer union and its byte limits, not initialization,
// controller authority or live workflow semantics.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeQuestionAnswer } from "./question-answer.mjs";

const [path] = process.argv.slice(2);
if (!path) throw new Error("usage: node question-answer-vectors.mjs <vector-path>");
const fixture = JSON.parse(readFileSync(path, "utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
let checked = 0;

for (const vector of fixture.cases) {
  const actual = decodeQuestionAnswer(vector.input);
  if (vector.error) {
    assert.equal(actual, null, vector.name);
  } else if (vector.decoded_choice_hex) {
    assert.deepEqual(actual, { choice_id: Buffer.from(vector.decoded_choice_hex, "hex") }, vector.name);
  } else if (vector.decoded.choice_id !== undefined) {
    assert.deepEqual(actual, { choice_id: Buffer.from(vector.decoded.choice_id, "utf8") }, vector.name);
  } else {
    assert.deepEqual(actual, vector.decoded, vector.name);
  }
  checked += 1;
}

const text = "é".repeat(4096);
assert.deepEqual(decodeQuestionAnswer({ text }), { text });
assert.equal(decodeQuestionAnswer({ text: text + "x" }), null);
assert.equal(decodeQuestionAnswer({ text: "\ud800" }), null);
const bytes = Buffer.alloc(65536, 255);
assert.deepEqual(decodeQuestionAnswer({ choice_id: bytes.toString("base64url") }), { choice_id: bytes });
assert.equal(decodeQuestionAnswer({ choice_id: Buffer.concat([bytes, Buffer.from("x")]).toString("base64url") }), null);
process.stdout.write(JSON.stringify({ contract: fixture.contract, checked, boundary_checks: 5 }) + "\n");
