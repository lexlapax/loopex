// Concept
//
// A client for the Loopex experimental public session protocol, written for an
// independent implementation to read. It speaks the wire and nothing else: it
// holds no session state the server owns, invents no identity, and interprets
// no record it was not given.
//
// Technical depth
//
// Plain JavaScript that Node runs directly. There is no build step, no
// package manifest and no dependency, because a second package manager in this
// repository would cost every lane a lockfile and an install for a client whose
// whole job is to prove a byte contract. What a type checker would have caught
// is caught instead by the server: every field is validated on arrival there,
// and this client asserts the refusals as carefully as the successes.
//
// Framing is one JSON object per line. The client never sends a carriage
// return, never sends two objects on one line, and reads its own input the same
// way, because a client that was lenient about framing would not notice a
// server that was.

import { spawn } from "node:child_process";

const GENERATION = "loopex.experimental/1";

// Concept: the connection to one server process.
//
// Technical depth: the process is a foreground host. Its loss is the session's
// loss as far as this client is concerned, which is why nothing here tries to
// reconnect: reconnection would imply a residency the protocol does not promise.
export class Connection {
  #child;
  #buffer = "";
  #pending = new Map();
  #events = [];
  #progress = [];
  #waiters = [];
  #closed = false;
  #nextRequest = 0;

  constructor(command, args, options = {}) {
    this.#child = spawn(command, args, {
      stdio: ["pipe", "pipe", options.stderr ?? "inherit"],
      env: options.env ?? process.env,
    });

    this.#child.stdout.setEncoding("utf8");
    this.#child.stdout.on("data", (chunk) => this.#absorb(chunk));
    this.#child.on("exit", () => {
      this.#closed = true;
      for (const { reject } of this.#pending.values()) {
        reject(new Error("the server process ended"));
      }
      this.#pending.clear();
      this.#release();
    });
  }

  // Concept: one request, one correlated answer.
  //
  // Technical depth: the request identity is generated here and never reused
  // while in flight, which is what lets the server answer out of order without
  // this client mistaking one answer for another. Records that carry no
  // identity are not answers and are queued for whoever asked to read them.
  async request(method, fields = {}) {
    if (this.#closed) throw new Error("the connection is closed");

    const requestId = `c${this.#nextRequest++}`;
    const frame = JSON.stringify({ method, request_id: requestId, ...fields });

    if (frame.includes("\n")) throw new Error("a frame may not contain a newline");

    const answer = new Promise((resolve, reject) => {
      this.#pending.set(requestId, { resolve, reject });
    });

    this.#child.stdin.write(frame + "\n");
    return answer;
  }

  async initialize(capabilities = []) {
    const reply = await this.request("initialize", {
      generations: [GENERATION],
      capabilities,
    });

    if (reply.type !== "initialized") {
      throw new Error(`initialization refused: ${reply.code ?? "unknown"}`);
    }

    if (reply.selected_generation !== GENERATION) {
      throw new Error("the server selected a generation this client did not offer");
    }

    this.limits = reply.limits;
    this.schemaDigest = reply.exact_schema_sha256;
    this.methods = reply.supported_methods;
    return reply;
  }

  // Concept: wait until the server has published an event this client is
  // looking for.
  //
  // Technical depth: durable events arrive without being asked for, so a client
  // that polled would either spin or miss them. The deadline is the client's
  // own patience and is never read as a verdict about the session: a timeout
  // here means this client stopped waiting, not that the run failed.
  async waitForEvent(predicate, timeoutMs = 10_000) {
    const found = this.#events.find(predicate);
    if (found) return found;

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#waiters = this.#waiters.filter((waiter) => waiter.timer !== timer);
        reject(new Error("no matching event arrived before this client stopped waiting"));
      }, timeoutMs);

      this.#waiters.push({ predicate, resolve, timer });
    });
  }

  events() {
    return [...this.#events];
  }

  progress() {
    return [...this.#progress];
  }

  close() {
    this.#closed = true;
    this.#child.stdin.end();
  }

  // Concept: the server process dies without being told anything.
  //
  // Technical depth: closing standard input is an orderly shutdown and is a
  // different event entirely. A kill leaves no chance to finish a write, run a
  // shutdown, or say goodbye, which is the point: what survives it survived
  // because it was already durable, not because anything tidied up.
  kill() {
    this.#closed = true;
    this.#child.kill("SIGKILL");
  }

  async ended() {
    if (this.#child.exitCode !== null) return this.#child.exitCode;
    return new Promise((resolve) => this.#child.on("exit", resolve));
  }

  #absorb(chunk) {
    this.#buffer += chunk;

    let newline;
    while ((newline = this.#buffer.indexOf("\n")) !== -1) {
      const line = this.#buffer.slice(0, newline);
      this.#buffer = this.#buffer.slice(newline + 1);
      if (line.length > 0) this.#deliver(JSON.parse(line));
    }
  }

  #deliver(record) {
    if (record.type === "event") {
      this.#events.push(record.event);
      this.#release();
      return;
    }

    if (record.type === "progress") {
      this.#progress.push(record.progress);
      return;
    }

    const waiting = record.request_id && this.#pending.get(record.request_id);

    if (waiting) {
      this.#pending.delete(record.request_id);
      waiting.resolve(record);
      return;
    }

    // An uncorrelated error is the server telling this client something about
    // the connection rather than about a request. It is kept where a caller can
    // see it rather than thrown at whichever request happened to be in flight.
    this.uncorrelated ??= [];
    this.uncorrelated.push(record);
  }

  #release() {
    this.#waiters = this.#waiters.filter((waiter) => {
      const found = this.#events.find(waiter.predicate);
      if (!found) return true;

      clearTimeout(waiter.timer);
      waiter.resolve(found);
      return false;
    });
  }
}

// Concept: the wire representations, as the four functions a client needs.
//
// Technical depth: identities and bytes are unpadded base64url, and quantities
// are canonical decimal strings. A client that used padded base64 or sent a
// number where a decimal string belongs is refused by the server, which is the
// behaviour these helpers exist to keep this client on the right side of.
export const wire = {
  identity(bytes) {
    return Buffer.from(bytes, "utf8").toString("base64url");
  },

  decodeIdentity(value) {
    return Buffer.from(value, "base64url").toString("utf8");
  },

  bytes(value) {
    return Buffer.from(value).toString("base64url");
  },

  decodeBytes(value) {
    return Buffer.from(value, "base64url");
  },

  u64(value) {
    return String(value);
  },

  decodeU64(value) {
    return BigInt(value);
  },

  reference(compact) {
    const members = {
      digest: compact.digest,
      locator: compact.locator,
      size: String(compact.size),
      use_locator: compact.use_locator,
    };

    return Buffer.from(JSON.stringify(sorted(members)), "utf8").toString("base64url");
  },
};

// The server encodes object members in sorted order and compares bytes, so a
// client building an opaque value has to sort too.
function sorted(object) {
  return Object.fromEntries(Object.keys(object).sort().map((key) => [key, object[key]]));
}

export { GENERATION };
