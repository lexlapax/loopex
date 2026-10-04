// Concept
// Identify the actual run or compact command owning a public checkpoint.
//
// Technical depth
// Independently decode the closed ADR 0043 owner object. Its identity stays
// an opaque Buffer; parsing grants no authority and proves no journal binding.

export function decodeCheckpointOwner(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value) ||
      Object.getPrototypeOf(value) !== Object.prototype || Object.keys(value).length !== 2 ||
      !Object.hasOwn(value, "kind") || !Object.hasOwn(value, "id") ||
      !["run", "compact"].includes(value.kind) || typeof value.id !== "string" ||
      value.id.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value.id)) return null;
  const id = Buffer.from(value.id, "base64url");
  return id.length >= 1 && id.length <= 65536 && id.toString("base64url") === value.id
    ? { kind: value.kind, id } : null;
}
