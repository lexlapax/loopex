// Concept
//
// A client for a running Loopex daemon, written for an independent
// implementation to read. It speaks generation 4 of the experimental session
// protocol over the daemon's Unix-domain socket and nothing else: it holds no
// session state the daemon owns, invents no identity, and grants itself no
// authority — every mutation it sends carries the writer epoch the daemon
// granted it.
//
// Technical depth
//
// Plain JavaScript on Node's standard library, with the same framing rules as
// the foreground client: one compact JSON object per LF, no carriage return,
// and correlated answers matched by a request identity generated here and
// never reused while in flight. Records without a request identity — durable
// events, progress, `detached`, `daemon.stopping` and `daemon.notice` — are
// kept in arrival order for whoever asks. The wire helpers are shared with the
// foreground client so both encode identities, bytes and quantities alike.

import net from "node:net";
import { wire } from "./loopex-client.mjs";
import { decodeCheckpointOwner } from "./checkpoint-owner.mjs";
import { decodeMaintenanceView } from "./maintenance-view.mjs";
import { decodeCompactCompletion } from "./compact-result.mjs";
import { decodeToolFinished } from "./tool-finished.mjs";
import { CURRENT_CONTRACTS, matchesContractIdentity } from "./contract-manifest.mjs";

export const GENERATION = CURRENT_CONTRACTS.daemon.generation;

export class DaemonConnection {
  #socket;
  #buffer = "";
  #pending = new Map();
  #events = [];
  #notices = [];
  #waiters = [];
  #closed = false;
  #nextRequest = 0;
  #initialization = "uninitialized";

  static open(path) {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(path);
      socket.once("connect", () => resolve(new DaemonConnection(socket)));
      socket.once("error", reject);
    });
  }

  constructor(socket) {
    this.#socket = socket;
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => this.#absorb(chunk));
    socket.on("close", () => {
      this.#closed = true;
      for (const { reject } of this.#pending.values()) {
        reject(new Error("the daemon connection closed"));
      }
      this.#pending.clear();
      this.#release();
    });
  }

  async request(method, fields = {}) {
    if (this.#closed) throw new Error("the connection is closed");
    if (Object.hasOwn(fields, "method") || Object.hasOwn(fields, "request_id")) {
      throw new Error("request envelope fields cannot be overridden");
    }
    if (method !== "initialize" && this.#initialization !== "verified") {
      throw new Error("session requests require verified initialization");
    }
    if (method === "initialize" && this.#initialization === "negotiating") {
      throw new Error("initialization is already in flight");
    }

    const requestId = `n${this.#nextRequest++}`;
    const frame = JSON.stringify({ ...fields, method, request_id: requestId });
    if (frame.includes("\n")) throw new Error("a frame may not contain a newline");

    const prior = this.#initialization;
    if (method === "initialize") this.#initialization = "negotiating";
    const answer = new Promise((resolve, reject) => {
      this.#pending.set(requestId, { resolve, reject });
    });
    this.#socket.write(frame + "\n");
    const reply = await answer;
    if (method === "initialize") {
      if (reply.type === "initialized") {
        if (!matchesContractIdentity(reply, CURRENT_CONTRACTS.daemon)) {
          this.#initialization = "refused";
          this.close();
          throw new Error("the server contract identity does not match this client");
        }
        this.#initialization = "verified";
        this.limits = reply.limits;
        this.schemaDigest = reply.exact_schema_sha256;
        this.methods = reply.supported_methods;
      } else {
        this.#initialization = reply.code === "invalid_request" || reply.code === "already_initialized"
          ? prior : "refused";
      }
    }
    return reply;
  }

  async initialize(capabilities = []) {
    const reply = await this.request("initialize", {
      generations: [GENERATION],
      capabilities,
    });
    if (reply.type !== "initialized") {
      throw new Error(`initialization refused: ${reply.code ?? "unknown"}`);
    }
    return reply;
  }

  // Concept: wait for a durable event this client is looking for.
  //
  // Technical depth: the deadline is this client's patience, never a verdict
  // about the session.
  async waitForEvent(predicate, timeoutMs = 60_000) {
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

  notices() {
    return [...this.#notices];
  }

  close() {
    this.#closed = true;
    this.#socket.end();
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
      if (record.event.kind === "context.compacted" &&
          (decodeCheckpointOwner(record.event.data?.owner) === null ||
           Object.hasOwn(record.event.data, "run_id"))) throw new Error("invalid checkpoint owner");
      if (record.event.kind === "context.maintenance_changed" &&
          decodeMaintenanceView(record.event.data) === null) throw new Error("invalid maintenance view");
      if (record.event.kind === "context.compaction_finished" &&
          decodeCompactCompletion(record.event.data) === null) throw new Error("invalid compact completion");
      if (record.event.kind === "tool.finished" &&
          decodeToolFinished(record.event.data) === null) throw new Error("invalid tool terminal");
      this.#events.push(record.event);
      this.#release();
      return;
    }

    const waiting = record.request_id && this.#pending.get(record.request_id);

    if (waiting) {
      this.#pending.delete(record.request_id);
      waiting.resolve(record);
      return;
    }

    if (record.type !== "progress") this.#notices.push(record);
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

export { wire };
