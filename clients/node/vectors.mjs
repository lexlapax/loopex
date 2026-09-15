// Concept
//
// The conformance vectors, executed by an independent implementation. This
// reads the same file the Elixir suite reads, decodes each case's exact wire
// bytes with its own framing rules, and reports which it admitted and which it
// refused.
//
// Technical depth
//
// It shares no code with the server. `JSON.parse` is not the contract: it
// accepts a duplicate member by keeping the last one, accepts a number the
// contract cannot round-trip, and says nothing about trailing bytes or the line
// framing. So the rules are implemented here over the raw text, which is the
// only way an independent client proves anything — a client that called the
// server's codec would be testing the server against itself.
//
// What it decides per case is narrow and stated: whether the frame is
// well-formed. A case whose expectation begins `protocol_error` must be refused
// by framing alone; every other case must decode, because whatever is wrong
// with it is wrong above the codec and is not this file's business.
//
// Usage: node vectors.mjs <path-to-vectors.json>

import { readFileSync } from "node:fs";

const [path] = process.argv.slice(2);

if (!path) {
  console.error("usage: node vectors.mjs <path-to-vectors.json>");
  process.exit(2);
}

const document = JSON.parse(readFileSync(path, "utf8"));
const results = [];

for (const testCase of document.cases) {
  const bytes = Buffer.from(testCase.raw_hex, "hex");
  results.push({ id: testCase.id, admitted: admits(bytes), expect: testCase.expect });
}

process.stdout.write(JSON.stringify({ format: document.format, results }) + "\n");

// Concept: whether these exact bytes are one well-formed frame.
//
// Technical depth: one object per line, LF only. The trailing newline is the
// framing and everything before it must be exactly one object, so a carriage
// return, a second object, trailing bytes and an unterminated value are all
// refused here rather than repaired.
function admits(bytes) {
  const text = bytes.toString("utf8");

  // Invalid UTF-8 survives the decode as a replacement character, which no
  // conforming frame contains.
  if (text.includes("�")) return false;
  if (!text.endsWith("\n")) return false;

  const line = text.slice(0, -1);
  if (line.includes("\n") || line.includes("\r")) return false;

  // Control characters are refused inside a frame, not only inside strings:
  // a frame is one line and nothing in it is allowed to end one.
  for (const character of line) {
    if (character.codePointAt(0) < 0x20) return false;
  }

  let parsed;

  try {
    parsed = JSON.parse(line);
  } catch {
    return false;
  }

  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return false;

  return !hasDuplicateMember(line) && everyNumberIsAdmissible(line);
}

// Concept: a member written twice.
//
// Technical depth: `JSON.parse` keeps the last one silently, so the duplicate
// has to be found in the text. This walks the string honestly rather than
// pattern-matching, because a key's characters can appear inside a value.
function hasDuplicateMember(line) {
  const seen = [];
  let depth = 0;
  let index = 0;

  while (index < line.length) {
    const character = line[index];

    if (character === '"') {
      const { value, next } = readString(line, index);
      if (value === null) return false;
      const rest = line.slice(next).replace(/^\s*/, "");

      if (rest.startsWith(":")) {
        seen[depth] ??= new Set();
        if (seen[depth].has(value)) return true;
        seen[depth].add(value);
      }

      index = next;
      continue;
    }

    if (character === "{" || character === "[") {
      depth += 1;
      seen[depth] = new Set();
    } else if (character === "}" || character === "]") {
      depth -= 1;
    }

    index += 1;
  }

  return false;
}

function readString(line, start) {
  let index = start + 1;
  let value = "";

  while (index < line.length) {
    const character = line[index];

    if (character === "\\") {
      value += line.slice(index, index + 2);
      index += 2;
      continue;
    }

    if (character === '"') return { value, next: index + 1 };

    value += character;
    index += 1;
  }

  return { value: null, next: line.length };
}

// Concept: a number the contract can carry.
//
// Technical depth: integers only, inside the range a double represents exactly.
// A fraction or an exponent is refused rather than rounded, because a client
// that rounded would agree with a server that did not.
function everyNumberIsAdmissible(line) {
  const numbers = line.replace(/"(?:[^"\\]|\\.)*"/g, '""').match(/-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?/g);

  if (!numbers) return true;

  return numbers.every((literal) => {
    if (/[.eE]/.test(literal)) return false;
    const value = Number(literal);
    return Number.isSafeInteger(value);
  });
}
