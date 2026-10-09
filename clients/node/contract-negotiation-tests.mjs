// Concept
// The independent connection clients send no session request until their exact
// current contract is verified and close on a mismatched identity.
// Technical depth
// Exercise the actual child-process and Unix-socket clients against controlled
// peers. The peers record every incoming frame, so local refusal and absence of
// replay are observable. Native server negotiation remains a separate proof.
import assert from "node:assert/strict";
import net from "node:net";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { appendFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Connection } from "./loopex-client.mjs";
import { DaemonConnection } from "./daemon-client.mjs";
import { CURRENT_CONTRACTS } from "./contract-manifest.mjs";

function responder(kind, mode) {
  let consumed = false;
  const pin = CURRENT_CONTRACTS[kind];
  return frame => {
    const correlation = { request_id: frame.request_id };
    if (frame.method !== "initialize") return { type: "result", ...correlation, method: frame.method, result: {} };
    if (Object.keys(frame).sort().join(",") !== "capabilities,generations,method,request_id" ||
        !Array.isArray(frame.generations) || frame.generations.length === 0 ||
        frame.generations.some(value => typeof value !== "string") || !Array.isArray(frame.capabilities)) {
      return { type: "error", ...correlation, code: "invalid_request", message: "invalid initialization" };
    }
    if (consumed) return { type: "error", ...correlation, code: "already_initialized", message: "negotiation already attempted" };
    consumed = true;
    if (!frame.generations.includes(pin.generation)) {
      return { type: "error", ...correlation, code: "unsupported_generation", message: "no current generation" };
    }
    return {
      type: "initialized", ...correlation,
      selected_generation: mode === "wrong_generation" ? CURRENT_CONTRACTS[kind === "foreground" ? "daemon" : "foreground"].generation : pin.generation,
      exact_schema_sha256: mode === "wrong_digest" ? "0".repeat(64) : pin.schemaDigest,
      supported_methods: [], record_families: [], limits: {}, unsupported_capabilities: frame.capabilities,
    };
  };
}

if (process.argv[2] === "--peer") {
  const [, , , mode, log] = process.argv;
  const respond = responder("foreground", mode);
  const lines = createInterface({ input: process.stdin });
  lines.on("line", line => {
    appendFileSync(log, line + "\n");
    process.stdout.write(JSON.stringify(respond(JSON.parse(line))) + "\n");
  });
} else {
  const root = mkdtempSync(join(tmpdir(), "loopex-client-contract-"));
  let peers = 0;
  let scenarios = 0;
  let mismatchFrames = 0;
  async function withPeer(kind, mode, action) {
    const id = peers++;
    const frames = [];
    let connection;
    let server;
    let log;
    let peerClosed;
    if (kind === "foreground") {
      log = join(root, `peer-${id}.jsonl`);
      writeFileSync(log, "");
      connection = new Connection(process.execPath, [fileURLToPath(import.meta.url), "--peer", mode, log]);
    } else {
      const respond = responder(kind, mode);
      server = net.createServer(socket => {
        peerClosed = once(socket, "close");
        const lines = createInterface({ input: socket });
        lines.on("line", line => {
          const frame = JSON.parse(line);
          frames.push(frame);
          socket.write(JSON.stringify(respond(frame)) + "\n");
        });
        socket.on("end", () => socket.end());
      });
      server.listen(join(root, `peer-${id}.sock`));
      await once(server, "listening");
      connection = await DaemonConnection.open(join(root, `peer-${id}.sock`));
    }
    try {
      await action(connection);
    } finally {
      connection.close();
      if (kind === "foreground") {
        await connection.ended();
        for (const line of readFileSync(log, "utf8").trim().split("\n").filter(Boolean)) frames.push(JSON.parse(line));
      } else {
        await peerClosed;
        await new Promise(resolve => server.close(resolve));
      }
    }
    return frames;
  }

  try {
    for (const kind of ["foreground", "daemon"]) {
      const pin = CURRENT_CONTRACTS[kind];
      const wrong = CURRENT_CONTRACTS[kind === "foreground" ? "daemon" : "foreground"].generation;
      const success = await withPeer(kind, "good", async connection => {
        await assert.rejects(connection.request("session.create", { session_options: { version: 1 } }), /verified initialization/);
        await assert.rejects(connection.request("initialize", { method: "session.create" }), /cannot be overridden/);
        await connection.initialize();
        assert.equal(connection.schemaDigest, pin.schemaDigest);
        assert.equal((await connection.request("session.inspect", { session_id: "cw" })).type, "result");
        await assert.rejects(connection.initialize(), /already_initialized/);
        assert.equal((await connection.request("session.inspect", { session_id: "cw" })).type, "result");
      });
      assert.deepEqual(success.map(frame => frame.method), ["initialize", "session.inspect", "initialize", "session.inspect"]);
      scenarios++;

      const malformed = await withPeer(kind, "good", async connection => {
        const pending = connection.request("initialize", { generations: [], capabilities: [] });
        await assert.rejects(connection.initialize(), /already in flight/);
        assert.equal((await pending).code, "invalid_request");
        await assert.rejects(connection.request("session.prompt", { command_id: "Yw" }), /verified initialization/);
        assert.equal((await connection.initialize()).type, "initialized");
        await connection.request("session.inspect", { session_id: "cw" });
      });
      assert.deepEqual(malformed.map(frame => frame.method), ["initialize", "initialize", "session.inspect"]);
      scenarios++;

      for (const offered of [["loopex.experimental/1"], ["loopex.experimental/2"], ["loopex.session.v1-experimental"], [wrong]]) {
        const refused = await withPeer(kind, "good", async connection => {
          const reply = await connection.request("initialize", { generations: offered, capabilities: [] });
          assert.equal(reply.code, "unsupported_generation");
          for (const method of ["session.create", "session.attach", "session.resume", "session.acquire_control", "session.prompt", "session.configure", "session.compact"]) {
            await assert.rejects(connection.request(method, {}), /verified initialization/);
          }
          await assert.rejects(connection.initialize(), /already_initialized/);
          await assert.rejects(connection.request("session.abort", { command_id: "Yw" }), /verified initialization/);
        });
        assert.deepEqual(refused.map(frame => frame.method), ["initialize", "initialize"]);
      }
      scenarios++;

      for (const mode of ["wrong_digest", "wrong_generation"]) {
        const mismatch = await withPeer(kind, mode, async connection => {
          await assert.rejects(connection.initialize(), /contract identity/);
          await assert.rejects(connection.request("session.create", { command_id: "Yw", session_options: { version: 1 } }), /closed/);
          await assert.rejects(connection.initialize(), /closed/);
        });
        assert.deepEqual(mismatch.map(frame => frame.method), ["initialize"]);
        mismatchFrames += mismatch.filter(frame => frame.method !== "initialize").length;
        scenarios++;
      }

      for (const offered of [["loopex.experimental/1", wrong, pin.generation], [pin.generation, wrong, "loopex.experimental/2"]]) {
        const mixed = await withPeer(kind, "good", async connection => {
          assert.equal((await connection.request("initialize", { generations: offered, capabilities: [] })).selected_generation, pin.generation);
          await connection.request("session.inspect", { session_id: "cw" });
        });
        assert.deepEqual(mixed.map(frame => frame.method), ["initialize", "session.inspect"]);
      }
      scenarios++;
    }
    process.stdout.write(JSON.stringify({ transports: 2, scenarios, peer_connections: peers, mismatch_session_frames: mismatchFrames }) + "\n");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
