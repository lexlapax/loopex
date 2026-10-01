// Concept
// Decode the closed M7 answer union without deriving permission from an answer.
//
// Technical depth
// This independent implementation retains text as text and choice identities
// as opaque bytes. The enclosing client must verify M7 initialization before
// sending these branches; this decoder enables no protocol method by itself.

export function decodeQuestionAnswer(answer) {
  if (answer === null || typeof answer !== "object" || Array.isArray(answer)) return null;
  const keys = Object.keys(answer);
  if (keys.length !== 1) return null;
  const [key] = keys;
  const value = answer[key];

  if (key === "choice_id") {
    if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) return null;
    const bytes = Buffer.from(value, "base64url");
    if (bytes.length < 1 || bytes.length > 65536) return null;
    return { choice_id: bytes };
  }

  if (key === "text") {
    if (typeof value !== "string" || !value.isWellFormed()) return null;
    const bytes = Buffer.byteLength(value, "utf8");
    if (bytes < 1 || bytes > 8192) return null;
    return { text: value };
  }

  if (key === "disposition" && value === "declined") return { disposition: "declined" };
  return null;
}
