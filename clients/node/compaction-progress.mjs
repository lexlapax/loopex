// Concept
// Decode one permitted compaction attempt's activity without inferring outcome.
//
// Technical depth
// The accepted ADR 0054 payload has exactly six members and no closing variant.
// Opaque identities are Buffers and quantities are BigInt. Check inert data
// descriptors before reading members; this decoder grants no owner authority.
import { decodeCheckpointOwner } from "./checkpoint-owner.mjs";

const keys = ["kind", "episode_id", "owner", "stream_domain_id", "progress_sequence", "base_event_sequence"];

export function decodeCompactionProgress(value) {
  if (!closed(value, keys) || value.kind !== "context.compaction_progress" ||
      value.progress_sequence !== "0" || !closed(value.owner, ["kind", "id"])) return null;

  const episode = identity(value.episode_id, 65536, 87382);
  const owner = decodeCheckpointOwner(value.owner);
  const domain = identity(value.stream_domain_id, 32, 43);
  const base = quantity(value.base_event_sequence);
  if (episode === null || owner === null || domain === null || domain.length !== 32 ||
      !domain.every(byte => (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)) ||
      base === null) return null;

  return {
    kind: "context.compaction_progress",
    episode_id: episode,
    owner,
    stream_domain_id: domain,
    progress_sequence: 0n,
    base_event_sequence: base
  };
}

function closed(value, required) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const names = Reflect.ownKeys(descriptors);
  return names.length === required.length && names.every(key => typeof key === "string" &&
    required.includes(key) && Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}

function identity(value, maximum, encodedMaximum) {
  if (typeof value !== "string" || value.length > encodedMaximum || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= maximum && bytes.toString("base64url") === value ? bytes : null;
}

function quantity(value) {
  if (typeof value !== "string" || value.length > 20 || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const integer = BigInt(value);
  return integer.toString() === value && integer <= 18446744073709551615n ? integer : null;
}
